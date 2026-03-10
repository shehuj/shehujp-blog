# atechbroe-blog

A self-hosted [Ghost 6](https://ghost.org/) blog deployed to AWS EC2 via Docker, with a fully automated CI/CD pipeline — from code push to live production — using GitHub Actions and Terraform.

---

## Table of Contents

- [Overview](#overview)
- [Project Structure](#project-structure)
- [Branching Strategy](#branching-strategy)
- [Local Development](#local-development)
- [Infrastructure (Terraform)](#infrastructure-terraform)
- [CI/CD Pipeline](#cicd-pipeline)
- [SSL / TLS Setup](#ssl--tls-setup)
- [DNS Management](#dns-management)
- [Required GitHub Secrets](#required-github-secrets)
- [Operations](#operations)
- [Security Notes](#security-notes)

---

## Overview

| Property | Value |
| --- | --- |
| **CMS** | [Ghost 6](https://ghost.org/) on Alpine Linux |
| **Image base** | `ghost:6.14-alpine` |
| **Database** | MySQL 8.0 (production) / SQLite (local testing) |
| **Registry** | Docker Hub |
| **Hosting** | AWS EC2 (Amazon Linux 2023) |
| **Infra-as-Code** | Terraform ≥ 1.7 |
| **CI/CD** | GitHub Actions (OIDC — no long-lived AWS credentials) |
| **DNS** | AWS Route 53 (`atechbroe.com`) |

---

## Project Structure

```text
atechbroe-blog/
├── Dockerfile                          # Production-hardened Ghost 6 image
├── docker-compose.yml                  # Local dev stack: Ghost + MySQL
├── .env                                # Local secrets — never commit
├── .trivyignore                        # Suppressed upstream CVEs (Ghost node_modules)
│
├── terraform/
│   ├── backend.tf                      # Partial S3 backend (bucket/table injected at init)
│   ├── versions.tf                     # Terraform + provider version constraints
│   ├── providers.tf                    # AWS + random provider config
│   ├── variables.tf                    # Input variable declarations
│   ├── terraform.tfvars.example        # Copy → terraform.tfvars for local runs
│   ├── main.tf                         # EC2, EBS, EIP, CloudWatch
│   ├── security.tf                     # KMS, Security Group, IAM role
│   ├── secrets.tf                      # Secrets Manager (DB credentials)
│   ├── dns.tf                          # Route 53 hosted zone + A + CAA records
│   ├── outputs.tf                      # Instance ID, EIP, SSM connect command
│   └── userdata.sh                     # EC2 bootstrap: Docker, Ghost stack, systemd
│
└── .github/
    └── workflows/
        ├── ghost-CI.yml                # Build → Test → Security scan → Publish
        ├── atechbroe-infra.yml         # Terraform plan (dev) → apply (main)
        ├── atechbroe-deploy.yml        # Rolling restart via SSM after publish
        └── atechbroe-dns.yml           # Update Route 53 A records on IP change
```

---

## Branching Strategy

| Branch | What runs |
| --- | --- |
| `dev` (push / PR) | Build, test, security scan, Terraform plan |
| `main` (push / merge) | All of the above **+** Docker publish, Terraform apply, rolling deploy |
| `v*.*.*` tag | Build, test, scan, **+** Docker publish with semver tags |

> Work on `dev`, open a PR to `main`. The PR shows the Terraform plan as a comment and runs all tests before the merge button turns green.

---

## Local Development

### Quick start (SQLite — no database required)

```sh
docker run -d \
  --name atechbroe-blog \
  -p 2368:2368 \
  -e url=http://localhost:2368 \
  -e database__client=sqlite3 \
  -e database__connection__filename=/var/lib/ghost/content/data/ghost.db \
  -v ghost-content:/var/lib/ghost/content \
  ghost:6.14-alpine
```

Open `http://localhost:2368` — admin panel at `http://localhost:2368/ghost`.

### Full local stack (MySQL)

**1. Create your `.env`:**

```sh
cp .env.example .env  # or create manually
```

```env
GHOST_DB_PASSWORD=your_strong_password_here
MYSQL_ROOT_PASSWORD=your_strong_root_password_here
```

**2. Start the stack:**

```sh
docker compose up -d
docker compose logs -f ghost   # watch startup
```

Ghost waits for MySQL's health check before initialising. Data is persisted in named volumes (`ghost-content`, `ghost-db`) and survives restarts.

**3. Stop:**

```sh
docker compose down
```

### Build the image locally

```sh
docker build -t atechbroe-blog .
```

---

## Infrastructure (Terraform)

### AWS architecture

```text
                ┌──────────────────────────────────┐
                │           AWS Account            │
                │                                  │
  Internet ────▶│  Route 53 (atechbroe.com)        │
                │       │ A record → EIP           │
                │       ▼                          │
                │  Elastic IP ──▶ EC2 (AL2023)     │
                │                 ├── Nginx :80/443│
                │                 ├── Ghost :2368  │
                │                 ├── MySQL :3306  │
                │                 └── Certbot      │
                │                                  │
                │  EBS root (gp3, encrypted, KMS)  │
                │  EBS data (xfs, prevent_destroy) │
                │                                  │
                │  Secrets Manager ── DB passwords  │
                │  CloudWatch ──── container logs  │
                │  SSM Session Manager ── no SSH   │
                └──────────────────────────────────┘
```

### Backend setup (S3 + DynamoDB)

The Terraform state is stored remotely. Create the bucket and lock table once, then add them as GitHub Secrets:

```sh
# Create state bucket
aws s3api create-bucket --bucket <your-bucket-name> --region us-east-1
aws s3api put-bucket-versioning \
  --bucket <your-bucket-name> \
  --versioning-configuration Status=Enabled

# Create DynamoDB lock table
aws dynamodb create-table \
  --table-name <your-lock-table-name> \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

Then add `BACKEND_TF`, `DYNAMOTBALE_TF`, and `AWS_REGION` as GitHub Secrets (see [Required GitHub Secrets](#required-github-secrets)).

### Local `terraform init`

```sh
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars with your values

terraform init \
  -backend-config="bucket=$BACKEND_TF" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="dynamodb_table=$DYNAMOTBALE_TF"

terraform plan
terraform apply
```

### Key security features

| Feature | Implementation |
| --- | --- |
| No SSH required | AWS SSM Session Manager; SSH port closed by default |
| IMDSv2 enforced | Blocks SSRF attacks against instance metadata |
| KMS CMK encryption | EBS volumes + Secrets Manager use customer-managed keys |
| DB credentials | Stored in Secrets Manager — never in userdata or env files |
| IAM least privilege | EC2 role scoped to SSM, CloudWatch, KMS, and its own secret |
| Data volume survives replace | `prevent_destroy = true` on separate EBS volume |
| Auto security updates | `dnf-automatic` enabled on boot |

---

## CI/CD Pipeline

The four workflows form a complete build-to-production pipeline:

```text
Push to dev / PR opened
        │
        ▼
  ghost-CI.yml
  ├── build-and-test
  │     ├── Build image (GHA layer cache)
  │     ├── Start container with SQLite
  │     ├── Wait for HEALTHCHECK → healthy
  │     ├── Assert process user = node
  │     └── Assert HTTP 200 on :2368
  │
  ├── security-scan  (continue-on-error)
  │     ├── Rebuild for Trivy
  │     └── Trivy CRITICAL/HIGH scan (ignores .trivyignore)
  │
  └── [publish — main/tag pushes only]
        ├── Login to Docker Hub
        └── Build & push multi-arch (amd64 + arm64)
              Tags: :main  :sha-<commit>  :latest  :vX.Y.Z

  atechbroe-infra.yml
  └── plan  (all branches)
        ├── terraform fmt -check
        ├── terraform init  (backend from secrets)
        ├── terraform validate
        ├── terraform plan  (-detailed-exitcode)
        └── Post plan diff as PR comment

─────────────── merge to main ─────────────────

  atechbroe-infra.yml
  └── apply  (main only, production environment gate)
        ├── terraform init
        └── terraform apply  (uses saved plan artifact)

  atechbroe-deploy.yml  (triggered by ghost-CI success on main)
  └── deploy
        ├── Discover EC2 instance by Environment=production tag
        ├── SSM send-command: systemctl restart ghost
        │     └── systemd ExecStartPre pulls new Docker Hub image
        ├── Wait for SSM command Success
        └── Health check: curl atechbroe.com → HTTP 200
```

### Workflow files

| File | Trigger | Purpose |
| --- | --- | --- |
| `ghost-CI.yml` | Push/PR to `dev`/`main`, semver tags | Build, test, Trivy scan, publish |
| `atechbroe-infra.yml` | Push/PR to `dev`/`main` (`terraform/**`) | Terraform plan + apply |
| `atechbroe-deploy.yml` | After `ghost-CI` succeeds on `main` | Rolling restart via SSM |
| `atechbroe-dns.yml` | Manual (`workflow_dispatch`) | Update Route 53 A records |

### Docker image tags

| Event | Tags produced |
| --- | --- |
| Push to `main` | `:main`, `:sha-<commit>`, `:latest` |
| Push tag `v1.2.3` | `:1.2.3`, `:1.2`, `:sha-<commit>` |
| Push to `dev` | Build + test + scan only — no publish |
| Pull request | Build + test + scan only — no publish |

---

## SSL / TLS Setup

The EC2 instance boots with HTTP-only Nginx. After DNS is pointed at the Elastic IP, run the one-time certificate issuance via SSM:

```sh
# Connect to the instance
aws ssm start-session --target <instance-id> --region us-east-1

# Issue the certificate
sudo docker compose -f /opt/ghost/docker-compose.yml run --rm certbot \
  certonly --webroot -w /var/www/certbot \
  -d atechbroe.com -d www.atechbroe.com \
  --email you@example.com --agree-tos
```

Then update `/opt/ghost/nginx/conf.d/ghost.conf` to add the HTTPS server block and reload Nginx:

```sh
sudo docker compose -f /opt/ghost/docker-compose.yml exec nginx nginx -s reload
```

Certbot auto-renews every 12 hours via its built-in loop.

---

## DNS Management

Run the `atechbroe-dns.yml` workflow manually from **Actions → DNS — Update atechbroe.com → Run workflow** whenever the server IP changes (e.g. after EC2 replacement).

| Input | Description |
| --- | --- |
| `server_ip` | New IPv4 address. Leave blank to use the `SERVER_IP` secret. |
| `ttl` | DNS TTL in seconds (`60` / `300` / `3600`). Use `60` during migrations. |
| `dry_run` | Preview changes without applying. |

The workflow validates the IP, upserts both `atechbroe.com` and `www.atechbroe.com` A records, waits for Route 53 propagation, and verifies resolution from Google, Cloudflare, and Quad9.

---

## Required GitHub Secrets

Add these under **Settings → Secrets and variables → Actions**:

| Secret | Description |
| --- | --- |
| `AWS_REGION` | AWS region, e.g. `us-east-1` |
| `AWS_ROLE_ARN` | IAM role ARN for OIDC authentication (no static credentials) |
| `BACKEND_TF` | S3 bucket name for Terraform state |
| `DYNAMOTBALE_TF` | DynamoDB table name for Terraform state locking |
| `GHOST_URL` | Public blog URL, e.g. `https://atechbroe.com` |
| `DOCKERHUB_USERNAME` | Docker Hub username |
| `DOCKERHUB_TOKEN` | Docker Hub personal access token (not your password) |
| `ROUTE53_ZONE_ID` | Route 53 hosted zone ID for `atechbroe.com` |
| `SERVER_IP` | Current server Elastic IP (fallback for DNS workflow) |

### GitHub OIDC trust policy

The `AWS_ROLE_ARN` role must trust the GitHub OIDC provider with a condition scoped to this repository:

```json
{
  "StringLike": {
    "token.actions.githubusercontent.com:sub": "repo:your-org/atechbroe-blog:*"
  }
}
```

---

## Operations

### Connect to the instance (no SSH needed)

```sh
aws ssm start-session --target <instance-id> --region us-east-1
```

The instance ID is printed by `terraform output instance_id` or found in the EC2 console.

### View container logs

```sh
# On the instance via SSM
journalctl -u ghost -f

# Or from your workstation via CloudWatch
aws logs tail /ghost/production --follow --region us-east-1
```

### Check stack status

```sh
# On the instance
docker compose -f /opt/ghost/docker-compose.yml ps
```

### Manual rolling restart (pull latest image)

Trigger **Actions → Deploy — Rolling Restart Ghost on EC2 → Run workflow**, or from the instance:

```sh
sudo systemctl restart ghost
```

### Rollback

Re-tag the previous image on Docker Hub as `:latest`, then trigger the deploy workflow.

---

## Security Notes

- **Ghost 6** — upgraded from Ghost 5 to patch three critical CVEs:
  - `CVE-2026-26980` — SQL injection in Content API
  - `CVE-2026-29053` — RCE via malicious themes
  - `CVE-2026-29784` — Incomplete CSRF protections

- **CVE scanning** — Trivy runs on every push. Unfixed upstream CVEs in Ghost's `node_modules` are tracked in `.trivyignore` with documented risk assessments. The scan is non-blocking (`continue-on-error: true`) but results are visible in Actions.

- **Image pinning** — pin to a digest in production for immutable deploys:

  ```sh
  docker pull ghost:6.14-alpine
  docker inspect ghost:6.14-alpine --format '{{index .RepoDigests 0}}'
  ```

- **No long-lived AWS credentials** — all workflows authenticate via GitHub OIDC (`id-token: write`).

- **Secrets never leave AWS** — DB passwords are generated by Terraform, stored in Secrets Manager, and fetched by the EC2 instance at boot. They are not stored in GitHub, `.env`, or userdata.

- **No SSH** — access is exclusively through SSM Session Manager. The security group has no port 22 rule by default.
