# ── KMS key for EBS encryption ────────────────────────────────────────────────
resource "aws_kms_key" "ebs" {
  description             = "Ghost blog — EBS encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "ebs" {
  name          = "alias/ghost-blog-ebs-${var.environment}"
  target_key_id = aws_kms_key.ebs.key_id
}

# ── KMS key for CloudWatch Logs ───────────────────────────────────────────────
# CloudWatch Logs requires an explicit key policy granting the logs service
# principal permission to use the key. The default key policy (account root only)
# is not sufficient — without this grant, CreateLogGroup returns AccessDeniedException.
resource "aws_kms_key" "logs" {
  description             = "Ghost blog - CloudWatch Logs encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableIAMUserPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.aws_region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      }
    ]
  })
}

resource "aws_kms_alias" "logs" {
  name          = "alias/ghost-blog-logs-${var.environment}"
  target_key_id = aws_kms_key.logs.key_id
}

# ── Security Group ────────────────────────────────────────────────────────────
resource "aws_security_group" "ghost" {
  name        = "ghost-blog-${var.environment}"
  description = "Ghost blog - inbound HTTP from ALB only, SSH disabled by default"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "HTTP from ALB only"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # SSH only if an explicit CIDR is provided — prefer SSM Session Manager
  dynamic "ingress" {
    for_each = var.allowed_ssh_cidr != "" ? [1] : []
    content {
      description = "SSH (restricted)"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [var.allowed_ssh_cidr]
    }
  }

  egress {
    description      = "All outbound"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = { Name = "ghost-blog-${var.environment}" }
}

# ── IAM Role ──────────────────────────────────────────────────────────────────
resource "aws_iam_role" "ghost" {
  name = "ghost-blog-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# SSM Session Manager — connect without opening port 22
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ghost.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# CloudWatch Agent
resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.ghost.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Secrets Manager — read only, scoped to this secret
resource "aws_iam_role_policy" "secrets_read" {
  name = "ghost-secrets-read"
  role = aws_iam_role.ghost.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.ghost_db.arn
    }]
  })
}

# KMS — decrypt EBS volumes and secrets
resource "aws_iam_role_policy" "kms_decrypt" {
  name = "ghost-kms-decrypt"
  role = aws_iam_role.ghost.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
      Resource = [aws_kms_key.ebs.arn, aws_kms_key.secrets.arn, aws_kms_key.logs.arn]
    }]
  })
}

# CloudWatch Logs — for Docker awslogs driver
resource "aws_iam_role_policy" "cloudwatch_logs" {
  name = "ghost-cloudwatch-logs"
  role = aws_iam_role.ghost.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ]
      Resource = "arn:aws:logs:${var.aws_region}:*:log-group:/ghost-blog/*"
    }]
  })
}

resource "aws_iam_instance_profile" "ghost" {
  name = "ghost-blog-${var.environment}"
  role = aws_iam_role.ghost.name
}
