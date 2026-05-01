# Zero-Trust E-Permit Infrastructure

> **Qualisys Consulting DevOps Assessment** — Production-grade IaC, containerisation, and CI/CD for a government E-Permit microservice.

---

## Repository Structure

```
epermit-infrastructure/
├── .dockerignore
├── .gitignore
├── .github/
│   └── workflows/
│       └── pipeline.yml                # Task 3 — CI/CD pipeline
├── Dockerfile                          # Task 1 — Hardened, multi-stage image
├── package.json
├── package-lock.json
├── README.md
├── src/
│   └── index.js                        # Application source
└── terraform/
    ├── providers.tf                    # Terraform block, S3 backend, AWS provider
    ├── main.tf                         # Root orchestrator (module calls only)
    ├── variables.tf                    # All input variables (no hardcoded values)
    ├── outputs.tf                      # Root outputs
    ├── terraform.tfvars.example
    └── modules/
        ├── vpc/                        # Task 2a — HA VPC across 2 AZs
        │   ├── main.tf
        │   ├── variables.tf
        │   ├── outputs.tf
        │   └── versions.tf
        └── iam/                        # Task 2b — Least-privilege EC2 IAM Role
            ├── main.tf
            ├── variables.tf
            ├── outputs.tf
            └── versions.tf
```

---

## Task 1 — Dockerfile Design Decisions

The original "toxic" Dockerfile was rewritten with strict production requirements:

| Problem in Original | Fix Applied |
|---|---|
| `BUILD` stage re-ran `npm ci` redundantly (deps stage existed but wasn't used) | Three clean stages: `deps` (prod deps only), `build` (transpile), `runner` (final) |
| Ran as `root` | Dedicated system user/group `appuser:appgroup` (UID/GID 1001), created before any `COPY`; `USER appuser` before `CMD` |
| Cache-busting on every code change | `COPY package.json package-lock.json ./` before `RUN npm ci` — deps layer only rebuilds when manifests change |
| `curl` installed in the runtime image | Removed entirely. Healthcheck uses Node.js itself (`http.get`) — zero extra attack surface |
| No `--omit=dev` on production install | `npm ci --omit=dev --ignore-scripts` in `deps` stage — devDependencies never reach the final image |
| Files owned by root | All `COPY` instructions use `--chown=appuser:appgroup` |

### Supply-Chain Hardening

- `--ignore-scripts` on `npm ci` prevents malicious `postinstall` hooks from executing.
- The runner stage is derived from `node:20-alpine` (minimal OS surface) with no additional packages installed.
- The image is compatible with `docker run --read-only` for an additional Zero-Trust runtime constraint.

### Healthcheck Without curl

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD node -e "require('http').get('http://localhost:3000/health', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"
```

This uses the Node.js runtime (already present in the image) to perform the health check. Installing `curl` would add an additional binary to the image — an unnecessary attack surface in a Zero-Trust environment.

---

## Task 2 — Terraform Initialisation Guide

### Prerequisites

- [Terraform ≥ 1.7](https://developer.hashicorp.com/terraform/install)
- AWS CLI configured (`aws configure`) with a role that has permissions to create VPC, IAM, CloudWatch, and S3 endpoint resources
- An S3 bucket and DynamoDB table for remote state (see Step 0)

### Step 0 — Bootstrap Remote State (one-time, manual)

The S3 backend resources must exist before `terraform init` can run. Create them once:

```bash
# Create the state bucket (versioning is mandatory — enables point-in-time recovery)
aws s3api create-bucket \
  --bucket epermit-terraform-state-prod \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket epermit-terraform-state-prod \
  --versioning-configuration Status=Enabled

# Encrypt all state objects at rest
aws s3api put-bucket-encryption \
  --bucket epermit-terraform-state-prod \
  --server-side-encryption-configuration '{
    "Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]
  }'

# Block all public access (Zero-Trust: state must never be public)
aws s3api put-public-access-block \
  --bucket epermit-terraform-state-prod \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Create the DynamoDB lock table (prevents concurrent state corruption)
aws dynamodb create-table \
  --table-name epermit-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### Step 1 — Copy and Fill tfvars

```bash
cd terraform/
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — this file is in .gitignore and must never be committed
```

### Step 2 — Initialise

```bash
terraform init
```

Terraform connects to the S3 backend, downloads the AWS provider, and prepares the working directory.

### Step 3 — Review the Plan

```bash
# Use defaults (us-east-1, prod environment)
terraform plan

# Or override variables inline (e.g. for DR failover to eu-west-1)
terraform plan \
  -var="aws_region=eu-west-1" \
  -var="availability_zones=[\"eu-west-1a\",\"eu-west-1b\"]" \
  -var="public_subnet_cidrs=[\"10.0.1.0/24\",\"10.0.2.0/24\"]" \
  -var="private_subnet_cidrs=[\"10.0.11.0/24\",\"10.0.12.0/24\"]"
```

### Step 4 — Apply

```bash
terraform apply
```

Type `yes` when prompted. Terraform provisions the VPC, subnets, NAT Gateways, VPC Flow Logs, S3 VPC Endpoint, IAM role, and instance profile.

### Step 5 — Verify Outputs

```bash
terraform output
```

Key outputs: `vpc_id`, `public_subnet_ids`, `private_subnet_ids`, `ec2_instance_profile_name`, `s3_vpc_endpoint_id`.

### Step 6 — Destroy (cleanup)

```bash
terraform destroy
```

---

## Task 2 — Infrastructure Design Decisions

### VPC Module

| Design Choice | Rationale |
|---|---|
| One NAT Gateway per AZ | Eliminates the NAT Gateway as a single point of failure. A single NAT GW failure would take down outbound internet for private subnets in all AZs. |
| `map_public_ip_on_launch = false` on all subnets | EC2 instances never receive public IPs by accident. Public-facing traffic enters via the load balancer only. |
| VPC Flow Logs → CloudWatch | Zero-Trust requires full traffic visibility. Flow logs are the network audit trail — mandatory for detecting exfiltration or lateral movement. |
| S3 Gateway VPC Endpoint | S3 traffic (epermit document reads) never traverses the public internet via the NAT Gateway. The endpoint also carries a policy that restricts reachable buckets at the network layer — a second enforcement point independent of IAM. |

### IAM Module (Least Privilege + Zero-Trust)

The role enforces three independent layers:

1. **Trust Policy** — Only `ec2.amazonaws.com` can assume this role. A `Condition` on `aws:SourceAccount` prevents cross-account confused-deputy attacks.
2. **Permission Policy** — Explicit `Allow` only for `s3:ListBucket` and `s3:GetObject` on `epermit-secure-documents-prod`.
3. **Explicit Deny** — `s3:*` is denied on all resources that are NOT the allowed bucket. This `Deny` is unconditional and overrides any future accidental `Allow` (including AWS-managed policies attached by mistake).

```
IAM Evaluation: Does the request match an explicit Deny? → YES → DENIED (regardless of any Allow)
```

---

## Task 3 — CI/CD Pipeline

### GitHub Secrets Required

Configure in **Settings → Secrets and variables → Actions**:

| Secret | Description |
|---|---|
| `AWS_ECR_REGISTRY` | ECR registry URI, e.g. `123456789012.dkr.ecr.us-east-1.amazonaws.com` |
| `AWS_ECR_REPOSITORY` | ECR repository name, e.g. `epermit-api` |
| `AWS_ACCOUNT_ID` | AWS account ID (used to construct ECR login command) |
| `AWS_ACCESS_KEY_ID` | AWS access key — replace with OIDC for production (see below) |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key — replace with OIDC for production |
| `AWS_REGION` | Target region, e.g. `us-east-1` |

> **Production Upgrade — OIDC Federation:** Replace the static `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` secrets with an OIDC identity provider. GitHub Actions federates directly into an IAM Role, eliminating all long-lived static credentials from your repository. This is the production Zero-Trust posture for CI/CD → AWS authentication.

### Zero-Trust Hardening Applied to the Pipeline

| Control | Implementation |
|---|---|
| Pinned action SHAs | All `uses:` references are pinned to commit SHAs, not floating tags (e.g. `@v4`). A compromised tag cannot inject arbitrary code into the pipeline. |
| Minimal GITHUB_TOKEN permissions | `permissions:` block at workflow level grants only `contents: read`, `security-events: write`, `id-token: write`. Everything else is denied. |
| Security gate before push | Trivy scans the built image. `exit-code: "1"` causes the job to fail and the image is **never pushed to ECR** if a CRITICAL CVE is found. |
| `--no-cache` on build | Forces a clean build in CI — no stale cached layers that could mask vulnerabilities. |
| Immutable image tags | Images are tagged with the commit SHA (`${{ github.sha }}`). Every deployment is traceable to an exact commit. |
| SARIF report upload | Scan results are uploaded to the GitHub Security tab (`security-events: write`) for persistent audit visibility, even when the pipeline fails. |

### Pipeline Flow

```
push to main
     │
     ▼
┌─────────────────────────────────┐
│  1. Checkout (pinned SHA)       │
└─────────────┬───────────────────┘
              │
              ▼
┌─────────────────────────────────┐
│  2. Build Docker image          │
│     --no-cache, load=true       │
│     push=false                  │
└─────────────┬───────────────────┘
              │
              ▼
┌─────────────────────────────────┐   ← SECURITY GATE
│  3. Trivy Scan                  │
│     exit-code=1 on CRITICAL     │   Image never reaches ECR
│     *** PIPELINE FAILS HERE *** │   if this step fails
│     if vulnerabilities found    │
└─────────────┬───────────────────┘
              │  (only continues if scan passes)
              ▼
┌─────────────────────────────────┐
│  4. Upload SARIF to GitHub      │   always() — audit trail even on failure
│     Security tab                │
└─────────────┬───────────────────┘
              │
              ▼
┌─────────────────────────────────┐
│  5. Simulate ECR Login          │   Credentials via GitHub Secrets (masked)
└─────────────┬───────────────────┘
              │
              ▼
┌─────────────────────────────────┐
│  6. Simulate ECR Push           │   :sha (immutable) + :latest tags
└─────────────────────────────────┘
```

---

## Task 4 — Architecture Question: Cross-Region Disaster Recovery for Terraform State

> **Question:** If our AWS region (e.g., `us-east-1`) goes completely offline, explain step-by-step how our Terraform state file should be managed to ensure we can safely and immediately redeploy our infrastructure to a new region (e.g., `eu-west-1`) without corrupting our state.

### The Core Problem

The Terraform state file is the single source of truth for what infrastructure Terraform believes exists. If it is inaccessible, corrupted, or out of sync, `terraform apply` becomes dangerous — it may try to recreate resources that already exist, or destroy resources it cannot account for. Both outcomes are catastrophic for a government permit system.

---

### Before a Disaster — Prevention (Set Up in Advance)

**Step 1 — Enable Cross-Region Replication on the State Bucket**

Configure this once after the bootstrap step. Every write to the state file in `us-east-1` is automatically and continuously replicated to `eu-west-1`. Because versioning is already enabled, every previous state version is also replicated.

```bash
# Create the DR replica bucket in eu-west-1
aws s3api create-bucket \
  --bucket epermit-terraform-state-prod-dr-euwest1 \
  --create-bucket-configuration LocationConstraint=eu-west-1 \
  --region eu-west-1

aws s3api put-bucket-versioning \
  --bucket epermit-terraform-state-prod-dr-euwest1 \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket epermit-terraform-state-prod-dr-euwest1 \
  --server-side-encryption-configuration '{
    "Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]
  }'

aws s3api put-public-access-block \
  --bucket epermit-terraform-state-prod-dr-euwest1 \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
  --region eu-west-1

# Configure replication from us-east-1 → eu-west-1
aws s3api put-bucket-replication \
  --bucket epermit-terraform-state-prod \
  --replication-configuration '{
    "Role": "arn:aws:iam::ACCOUNT_ID:role/s3-replication-role",
    "Rules": [{
      "Status": "Enabled",
      "DeleteMarkerReplication": { "Status": "Enabled" },
      "Destination": {
        "Bucket": "arn:aws:s3:::epermit-terraform-state-prod-dr-euwest1",
        "StorageClass": "STANDARD",
        "ReplicationTime": { "Status": "Enabled", "Time": { "Minutes": 15 } },
        "Metrics": { "Status": "Enabled", "EventThreshold": { "Minutes": 15 } }
      }
    }]
  }'
```

`ReplicationTime` with an SLA of 15 minutes (S3 RTC) ensures the replica lags by no more than 15 minutes. For a state file that is at most kilobytes, replication in practice takes seconds.

**Step 2 — Replicate the DynamoDB Lock Table**

Enable [DynamoDB Global Tables](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/GlobalTables.html) to add `eu-west-1` as a replica region:

```bash
aws dynamodb create-global-table \
  --global-table-name epermit-terraform-locks \
  --replication-group RegionName=eu-west-1 \
  --region us-east-1
```

This ensures the distributed lock mechanism works in the DR region without any manual setup at failover time. Without this, two operators could run `terraform apply` simultaneously during a chaotic failover — the most common cause of state corruption.

---

### During a Disaster — Failover Execution

**Step 3 — Confirm `us-east-1` is Unreachable**

Before acting, verify the outage is real and not a transient API error. Check the [AWS Service Health Dashboard](https://health.aws.amazon.com/health/status). A transient error that self-resolves while a failover is mid-flight is the scenario most likely to produce state corruption.

**Step 4 — Identify the Latest Replicated State Version**

The S3 replication job may have been mid-flight when the region went down. Identify the most recent complete state object version in the DR bucket:

```bash
aws s3api list-object-versions \
  --bucket epermit-terraform-state-prod-dr-euwest1 \
  --prefix global/epermit/terraform.tfstate \
  --region eu-west-1 \
  --query 'Versions[?IsLatest==`true`]'
```

Download it locally as an offline backup before making any changes:

```bash
aws s3api get-object \
  --bucket epermit-terraform-state-prod-dr-euwest1 \
  --key global/epermit/terraform.tfstate \
  --version-id <LATEST_VERSION_ID> \
  --region eu-west-1 \
  terraform.tfstate.backup-$(date +%Y%m%d-%H%M%S)
```

**Step 5 — Inspect the State Before Any Apply**

```bash
# Point to the local backup temporarily
export TF_CLI_ARGS_plan="-state=terraform.tfstate.backup-*"
terraform state list
```

Verify the state reflects what was deployed in `us-east-1`. **Do not proceed if the state looks incomplete or corrupted.** A corrupted state applied to a new region can create orphaned resources that are expensive and difficult to clean up.

**Step 6 — Reconfigure the Terraform Backend to Point to `eu-west-1`**

Update the `backend "s3"` block in **`terraform/providers.tf`** (note: the backend is declared in `providers.tf`, not `main.tf`):

```hcl
backend "s3" {
  bucket         = "epermit-terraform-state-prod-dr-euwest1"  # ← DR bucket
  key            = "global/epermit/terraform.tfstate"
  region         = "eu-west-1"                                 # ← changed
  encrypt        = true
  dynamodb_table = "epermit-terraform-locks"                   # Global Table replica is active
}
```

Reinitialise Terraform to switch backends:

```bash
terraform init -reconfigure
```

Terraform migrates to the DR backend. The DynamoDB Global Table in `eu-west-1` immediately provides locking.

**Step 7 — Plan Against the DR Region**

```bash
terraform plan \
  -var="aws_region=eu-west-1" \
  -var="availability_zones=[\"eu-west-1a\",\"eu-west-1b\"]" \
  -var="public_subnet_cidrs=[\"10.0.1.0/24\",\"10.0.2.0/24\"]" \
  -var="private_subnet_cidrs=[\"10.0.11.0/24\",\"10.0.12.0/24\"]"
```

Carefully review the plan output. Because the old resources were in `us-east-1` (which is down), Terraform correctly detects they are unreachable and plans to **create new resources** in `eu-west-1`. This is expected and correct — a fresh stack in the new region. The state file tracks these new resources going forward.

**Step 8 — Apply to the DR Region**

```bash
terraform apply \
  -var="aws_region=eu-west-1" \
  -var="availability_zones=[\"eu-west-1a\",\"eu-west-1b\"]" \
  -var="public_subnet_cidrs=[\"10.0.1.0/24\",\"10.0.2.0/24\"]" \
  -var="private_subnet_cidrs=[\"10.0.11.0/24\",\"10.0.12.0/24\"]"
```

Infrastructure is live in `eu-west-1`. The state file in the DR bucket is updated atomically. The DynamoDB lock is acquired and released correctly.

---

### After Recovery

**Step 9 — Do NOT Touch `us-east-1` State Until the Region Is Confirmed Stable**

When `us-east-1` recovers, the original state bucket contains the old state — reflecting resources that no longer exist (they were recreated in `eu-west-1`). Running `terraform apply` against it would create duplicate infrastructure.

Choose one of two paths:

- **Stay in `eu-west-1` (recommended):** Update DNS, decommission `us-east-1` resources manually or with a targeted `terraform destroy -var="aws_region=us-east-1"`, and treat `eu-west-1` as the new primary. Update the backend block back to its permanent configuration pointing at the DR bucket (which is now the primary).
- **Migrate back to `us-east-1`:** Use `terraform state mv` to reconcile state entries, destroy `eu-west-1` resources, and migrate the backend back to `us-east-1`. This is operationally more complex and riskier during a recovery window.

---

### Why This Works — Key Principles

| Mechanism | Why It Matters |
|---|---|
| **S3 Versioning** | Every state write is a new immutable version. Rolling back to a known-good state is a single `get-object --version-id` call. No state is ever permanently lost. |
| **S3 Cross-Region Replication (with RTC)** | State is continuously mirrored with a 15-minute SLA. DR failover uses data that is at most minutes old, not hours. |
| **DynamoDB Global Tables** | The distributed lock prevents two operators from running `apply` simultaneously during a chaotic failover — the most common cause of state corruption. The replica is active and consistent before the disaster occurs. |
| **Immutable image tags** (pipeline) | Docker images tagged by commit SHA mean the exact binary that ran in `us-east-1` can be pulled into `eu-west-1` from ECR without a rebuild. |
| **`terraform plan` before `apply`** | The plan step is a mandatory sanity check. During DR, what Terraform intends to do must be reviewed by a human before resources are created. Never skip it. |
| **Region passed as variable** | The AWS provider region is a variable, not a hardcode. The same Terraform code targets `eu-west-1` with a single `-var` flag — no file changes, no risk of merge conflicts during an outage. |

---

*Prepared for Qualisys Consulting DevOps Assessment v1.0 — 2026*
