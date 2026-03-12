# shehujp-blog

A self-hosted [Ghost 6](https://ghost.org/) blog deployed to AWS EC2 via Docker, with a fully automated CI/CD pipeline — from code push to live production — using GitHub Actions and Terraform.

---

## Table of Contents

- [Overview](#overview)
- [Project Structure](#project-structure)
- [Branching Strategy](#branching-strategy)
- [Local Development](#local-development)
- [Infrastructure (Terraform)](#infrastructure-terraform)
- [CI/CD Pipeline](#cicd-pipeline)
- [SSL / TLS](#ssl--tls)
- [DNS Management](#dns-management)
- [GitHub Secrets](#github-secrets)
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
| **Hosting** | AWS EC2 (Amazon Linux 2023) behind ALB |
| **TLS** | AWS ACM certificate (auto-renewed) |
| **Infra-as-Code** | Terraform ≥ 1.7 |
| **CI/CD** | GitHub Actions |
| **DNS** | AWS Route 53 (`shehujp.com`) |

---

## Project Structure

```text
shehujp-blog/
├── Dockerfile                          # Production-hardened Ghost 6 image
├── docker-compose.yml                  # Local dev stack: Ghost + MySQL
├── .env                                # Local secrets — never commit
├── .trivyignore                        # Suppressed upstream CVEs (Ghost node_modules)
│
├── terraform/
│   ├── backend.tf                      # S3 remote state (bucket + region hardcoded)
│   ├── versions.tf                     # Terraform + provider version constraints
│   ├── providers.tf                    # AWS + random provider config
│   ├── variables.tf                    # Input variable declarations
│   ├── terraform.tfvars.example        # Copy → terraform.tfvars for local runs
│   ├── main.tf                         # EC2, EBS, EIP, CloudWatch
│   ├── security.tf                     # KMS, Security Groups, IAM role
│   ├── secrets.tf                      # Secrets Manager (DB credentials)
│   ├── acm.tf                          # ACM certificate + DNS validation
│   ├── alb.tf                          # ALB, target group, listeners
│   ├── dns.tf                          # Route 53 hosted zone + ALIAS + CAA records
│   ├── outputs.tf                      # Instance ID, ALB DNS, SSM connect command
│   └── scripts/
│       └── userdata.sh                 # EC2 bootstrap: Docker, Ghost stack, systemd
│
└── .github/
    └── workflows/
        ├── ghost-CI.yml                # Build → Test → Scan → Publish (main/tags)
        ├── shehujp-blog-infra.yml         # Terraform plan (PR) / apply (manual only)
        ├── shehujp-blog-deploy.yml        # Rolling restart via SSM (merge to main / manual)
        └── shehujp-blog-dns.yml           # Update Route 53 A records (manual only)
```

---

## Branching Strategy

| Event | What runs | What doesn't run |
| --- | --- | --- |
| Push to `dev` | Build, test, scan | Publish, infra plan, deploy |
| PR to `dev` / `main` | Build, test, scan, **Terraform plan** (posted as PR comment) | Publish, deploy |
| Merge to `main` | Build, test, scan, **publish**, **rolling deploy** | Terraform apply |
| `v*.*.*` tag | Build, test, scan, **publish** (semver tags) | Deploy, infra |
| Manual dispatch | Any workflow individually, with control inputs | — |

> Infra changes (Terraform apply) are **never automatic** — they require a manual dispatch with `action=apply`. This prevents unintended infrastructure changes from code-only merges.

> Open a PR to `main` to preview both CI results and the Terraform plan diff before merging.

---

## Local Development

### Quick start (SQLite — no database required)

```sh
docker run -d \
  --name shehujp-blog \
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
docker build -t shehujp-blog .
```

---

## Infrastructure (Terraform)

### AWS architecture

```text
                ┌──────────────────────────────────────┐
                │            AWS Account               │
                │                                      │
  Internet ────▶│  Route 53 (shehujp.com)                │
                │       │ ALIAS → ALB                  │
                │       ▼                              │
                │  ALB (HTTPS :443, ACM cert)          │
                │   ├── HTTP :80 → redirect to HTTPS   │
                │   └── HTTPS :443 → EC2 :80           │
                │       ▼                              │
                │  EC2 (AL2023)                        │
                │   ├── Nginx :80 (proxy to Ghost)     │
                │   ├── Ghost :2368                    │
                │   └── MySQL :3306                    │
                │                                      │
                │  ACM — auto-renewed TLS certificate  │
                │  EBS root (gp3, encrypted, KMS)      │
                │  EBS data (xfs, prevent_destroy)     │
                │                                      │
                │  Secrets Manager ── DB passwords     │
                │  CloudWatch ──── container logs      │
                │  SSM Session Manager ── no SSH       │
                └──────────────────────────────────────┘
```

### Local `terraform init` and deploy

The S3 backend bucket and region are configured directly in `backend.tf`. For local runs:

```sh
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars with your values

terraform init
terraform plan
terraform apply
```

> The CI workflow passes `-backend-config` flags to allow the DynamoDB lock table to be injected from the `DYNAMOTBALE_TF` secret without hardcoding it in source.

### Key security features

| Feature | Implementation |
| --- | --- |
| No SSH required | AWS SSM Session Manager; SSH port closed by default |
| TLS via ACM | ALB terminates HTTPS using ACM certificate; auto-renewed by AWS |
| EC2 not internet-exposed | Security group allows port 80 from ALB only; 443 never reaches EC2 |
| HTTP → HTTPS redirect | ALB listener redirects all port 80 traffic to HTTPS 301 |
| IMDSv2 enforced | Blocks SSRF attacks against instance metadata |
| KMS CMK encryption | EBS volumes + Secrets Manager + CloudWatch logs use customer-managed keys |
| DB credentials | Stored in Secrets Manager — never in userdata or env files |
| IAM least privilege | EC2 role scoped to SSM, CloudWatch, KMS, and its own secret |
| Data volume survives replace | `prevent_destroy = true` on separate EBS volume |
| Auto security updates | `dnf-automatic` enabled on boot |

---

## CI/CD Pipeline

### On pull request

```text
PR opened / updated
  │
  ├── ghost-CI.yml
  │     ├── build-and-test
  │     │     ├── Build image (GHA cache)
  │     │     ├── Start container (SQLite)
  │     │     ├── Wait for HEALTHCHECK → healthy
  │     │     ├── Assert process user = node
  │     │     └── Assert HTTP 200 on :2368
  │     └── security-scan  (continue-on-error)
  │           ├── Rebuild for Trivy
  │           └── Trivy CRITICAL/HIGH scan (.trivyignore applied)
  │
  └── shehujp-blog-infra.yml  (only when terraform/** or workflow file changes)
        ├── terraform fmt -check
        ├── terraform init
        ├── terraform validate
        ├── terraform plan  (-detailed-exitcode)
        └── Post plan diff as PR comment
```

### On merge to main

```text
Merge to main
  │
  ├── ghost-CI.yml
  │     ├── build-and-test  (same as PR)
  │     ├── security-scan   (same as PR)
  │     └── publish
  │           ├── Login to Docker Hub
  │           └── Build & push multi-arch (amd64 + arm64)
  │                 Tags: :main  :sha-<commit>  :latest
  │
  └── shehujp-blog-deploy.yml  (triggers when ghost-CI completes)
        ├── Discover EC2 by Environment=production tag
        ├── SSM send-command: systemctl restart ghost
        │     └── ExecStartPre pulls latest Docker Hub image
        ├── Wait for SSM command: Success
        └── Health check: HTTP 200 on shehujp.com
```

### Manual dispatch only

```text
Actions → Terraform — Plan / Apply → Run workflow
  └── shehujp-blog-infra.yml
        input: action = plan   →  plan only
        input: action = apply  →  plan + apply  (production gate)

Actions → Deploy — Rolling Restart → Run workflow
  └── shehujp-blog-deploy.yml
        input: force = true  →  restart regardless of new image

Actions → DNS — Update shehujp.com → Run workflow
  └── shehujp-blog-dns.yml
        inputs: server_ip / ttl / dry_run
```

### Workflow reference

| Workflow | Auto trigger | Manual inputs |
| --- | --- | --- |
| `ghost-CI.yml` | Push/PR to `dev`/`main`; semver tags | `publish` (bool), `skip_tests` (bool) |
| `shehujp-blog-infra.yml` | PR to `dev`/`main` (terraform/** changes) | `action`: `plan` / `apply` |
| `shehujp-blog-deploy.yml` | After `ghost-CI` succeeds on `main` | `force` (bool) |
| `shehujp-blog-dns.yml` | Manual only | `server_ip`, `ttl`, `dry_run` |

### Docker image tags

| Event | Tags produced |
| --- | --- |
| Merge / push to `main` | `:main`, `:sha-<commit>`, `:latest` |
| Push tag `v1.2.3` | `:1.2.3`, `:1.2`, `:sha-<commit>` |
| Push to `dev` / PR | Build + test + scan only — no publish |
| Manual dispatch with `publish=true` | Same tags as branch push |

---

## SSL / TLS

TLS is handled entirely by the **ALB + AWS Certificate Manager**. No manual certificate setup is required.

- Terraform provisions the ACM certificate for `shehujp.com` and `www.shehujp.com`
- ACM validates ownership automatically via DNS CNAME records in Route 53
- The ALB HTTPS listener uses the certificate and terminates TLS before traffic reaches the EC2 instance
- AWS automatically renews the certificate before expiry — no cron job or Certbot needed
- The EC2 security group only allows port 80 from the ALB; port 443 never reaches the instance

---

## DNS Management

Route 53 ALIAS records point automatically to the ALB — they update when the ALB scales or changes IPs with no manual intervention needed.

Run the `shehujp-blog-dns.yml` workflow manually from **Actions → DNS — Update shehujp.com → Run workflow** if you ever need to force-update the ALIAS target (e.g. after switching to a new ALB).

| Input | Description |
| --- | --- |
| `server_ip` | New IPv4 address. Leave blank to use the `SERVER_IP` secret. |
| `ttl` | DNS TTL in seconds (`60` / `300` / `3600`). Use `60` during migrations. |
| `dry_run` | Preview changes without applying. |

The workflow validates the IP, upserts both `shehujp.com` and `www.shehujp.com` records, waits for Route 53 propagation, and verifies resolution from Google, Cloudflare, and Quad9.

---

## GitHub Secrets

### Create an IAM user for CI

```sh
aws iam create-user --user-name github-actions-shehujp

# Attach permissions needed by Terraform + deploy + DNS workflows
aws iam attach-user-policy \
  --user-name github-actions-shehujp \
  --policy-arn arn:aws:iam::aws:policy/PowerUserAccess

aws iam attach-user-policy \
  --user-name github-actions-shehujp \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMFullAccess

# Generate access keys
aws iam create-access-key --user-name github-actions-shehujp
# → save AccessKeyId and SecretAccessKey — shown once only
```

### Add secrets to GitHub

Go to **Settings → Secrets and variables → Actions** and add:

| Secret | Value |
| --- | --- |
| `AWS_ACCESS_KEY_ID` | Access key ID from the step above |
| `AWS_SECRET_ACCESS_KEY` | Secret access key from the step above |
| `AWS_REGION` | `us-east-1` |
| `DYNAMOTBALE_TF` | DynamoDB table name for Terraform state locking |
| `GHOST_URL` | `https://www.shehujp.com` |
| `DOCKERHUB_USERNAME` | Docker Hub username |
| `DOCKERHUB_TOKEN` | Docker Hub personal access token (not your password) |
| `ROUTE53_ZONE_ID` | Route 53 hosted zone ID for `shehujp.com` (from `terraform output zone_id`) |
| `SERVER_IP` | EC2 Elastic IP (fallback for DNS workflow — from `terraform output instance_ip`) |

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

- **Secrets never leave AWS** — DB passwords are generated by Terraform, stored in Secrets Manager, and fetched by the EC2 instance at boot. They are not stored in GitHub, `.env`, or userdata.

- **No SSH** — access is exclusively through SSM Session Manager. The security group has no port 22 rule by default.
