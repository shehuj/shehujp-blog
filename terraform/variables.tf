variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment label attached to all resources"
  type        = string
  default     = "production"
}

variable "instance_type" {
  description = "EC2 instance type — Ghost requires at least 1 GB RAM"
  type        = string
  default     = "t3.small"
}

variable "ghost_url" {
  description = "Public URL of the Ghost blog including scheme, e.g. https://blog.example.com"
  type        = string
  default     = "https://www.shehujp.com"
}

variable "ghost_image" {
  description = "Docker Hub image to run, e.g. youruser/atechbroe-blog:latest"
  type        = string
  default     = "captaincloud01/atechbroe:main"
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to reach port 22. Leave empty to disable SSH (use SSM instead)."
  type        = string
  default     = ""
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 20
}

variable "data_volume_size_gb" {
  description = "Separate EBS data volume for Ghost content and MySQL (survives instance replacement)"
  type        = number
  default     = 30
}
