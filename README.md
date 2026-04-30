# Zero-Trust E-Permit Infrastructure

> **Qualisys Consulting DevOps Assessment** — Production-grade IaC, containerisation, and CI/CD for a government E-Permit microservice.

---

## Repository Structure

```
epermit-infrastructure/
├── Dockerfile                          # Task 1 — Hardened, multi-stage image
├── .github/
│   └── workflows/
│       └── pipeline.yml                # Task 3 — CI/CD pipeline
├── terraform/
│   ├── main.tf                         # Root orchestrator
│   ├── variables.tf                    # All input variables (no hardcoded values)
│   ├── outputs.tf                      # Root outputs
│   └── modules/
│       ├── vpc/                        # Task 2a — HA VPC across 2 AZs
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── outputs.tf
│       └── iam/                        # Task 2b — Least-privilege EC2 IAM Role
│           ├── main.tf
│           ├── variables.tf
│           └── outputs.tf
└── README.md
```

---

## Task 1 — Dockerfile Design Decisions

The original "toxic" Dockerfile was rewritten with three production requirements:

| Problem | Fix Applied |
|---|---|
| Ran as `root` | Created a dedicated system user `appuser` (UID 1001); `USER appuser` before `CMD` |
| Fat image (devDependencies included) | Multi-stage build: `deps` stage runs `npm ci --omit=dev`; `runner` stage copies only production modules |
| Cache-busting on every code change | `COPY package.json package-lock.json ./` before `RUN npm ci` — dependency layer only rebuilds when manifests change |

---

## Task 2 — Terraform Initialisation Guide

### Prerequisites

- [Terraform ≥ 1.7](https://developer.hashicorp.com/terraform/install)
- AWS CLI configured (`aws configure`) with a role that has permissions to create VPC, IAM, and S3 resources
- An S3 bucket and DynamoDB table for remote state (see below)

### Step 0 — Bootstrap Remote State (one-time, manual)

Before `terraform init` can run, the S3 backend resources must exist. Create them once:

```bash
# Create the state bucket (versioning is mandatory — enables point-in-time recovery)
aws s3api create-bucket \
  --bucket epermit-terraform-state-prod \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket epermit-terraform-state-prod \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket epermit-terraform-state-prod \
  --server-side-encryption-configuration '{
    "Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]
  }'

# Create the DynamoDB lock table (prevents concurrent state corruption)
aws dynamodb create-table \
  --table-name epermit-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### Step 1 — Initialise

```bash
cd terraform/
terraform init
```

Terraform will connect to the S3 backend, download the AWS provider, and prepare the working directory.

### Step 2 — Review the Plan

```bash
# Use defaults (us-east-1, prod environment)
terraform plan

# Or override variables for a different environment
terraform plan \
  -var="environment=staging" \
  -var="aws_region=eu-west-1" \
  -var="availability_zones=[\"eu-west-1a\",\"eu-west-1b\"]" \
  -var="public_subnet_cidrs=[\"10.0.1.0/24\",\"10.0.2.0/24\"]" \
  -var="private_subnet_cidrs=[\"10.0.11.0/24\",\"10.0.12.0/24\"]"
```

### Step 3 — Apply

```bash
terraform apply
```

Type `yes` when prompted. Terraform will provision the VPC, subnets, NAT gateways, IAM role, and instance profile.

### Step 4 — Verify Outputs

```bash
terraform output
```

Key outputs include `vpc_id`, `public_subnet_ids`, `private_subnet_ids`, and `ec2_instance_profile_name`.

### Step 5 — Destroy (cleanup)

```bash
terraform destroy
```

---

## Task 3 — CI/CD Pipeline

### GitHub Secrets Required

Configure these secrets in **Settings → Secrets and variables → Actions**:

| Secret | Description |
|---|---|
| `AWS_ECR_REGISTRY` | Your ECR registry URI, e.g. `123456789012.dkr.ecr.us-east-1.amazonaws.com` |
| `AWS_ECR_REPOSITORY` | ECR repository name, e.g. `epermit-api` |
| `AWS_ACCESS_KEY_ID` | AWS access key (or use OIDC — see note below) |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key |
| `AWS_REGION` | Target region, e.g. `us-east-1` |

> **Security Note:** For production, replace the static access key secrets with an [OIDC identity provider](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services). This eliminates long-lived credentials entirely — GitHub Actions federates directly into an AWS IAM Role.

### Pipeline Flow

```
push to main
     │
     ▼
┌─────────────────────────────┐
│  1. Checkout source code    │
└────────────┬────────────────┘
             │
             ▼
┌─────────────────────────────┐
│  2. Build Docker image      │  ← load=true (local daemon), push=false
│     (multi-stage, cached)   │
└────────────┬────────────────┘
             │
             ▼
┌─────────────────────────────┐
│  3. Trivy Security Scan     │  ← exit-code 1 on CRITICAL CVEs
│     PIPELINE FAILS HERE     │  ← image never reaches ECR if vulnerable
│     if vulnerabilities      │
└────────────┬────────────────┘
             │  (only continues if scan passes)
             ▼
┌─────────────────────────────┐
│  4. ECR Login (masked creds)│
└────────────┬────────────────┘
             │
             ▼
┌─────────────────────────────┐
│  5. Push image to ECR       │  ← tagged with commit SHA (immutable)
│     :sha + :latest          │
└─────────────────────────────┘
```

---

## Task 4 — Architecture Question: Cross-Region Disaster Recovery for Terraform State

> **Question:** If our AWS region (e.g., `us-east-1`) goes completely offline, how should our Terraform state file be managed to ensure we can safely and immediately redeploy our infrastructure to a new region (e.g., `eu-west-1`) without corrupting our state?

### The Core Problem

The Terraform state file is the single source of truth for what infrastructure Terraform believes exists. If it is inaccessible, corrupted, or out of sync, `terraform apply` becomes dangerous — it may try to recreate resources that already exist, or destroy resources it can't account for.

### Step-by-Step DR Procedure

#### Before a disaster — Prevention (set up in advance)

**Step 1 — Enable Cross-Region Replication on the State Bucket**

This is configured once and protects you automatically. Replicate the state S3 bucket from `us-east-1` to `eu-west-1`:

```bash
aws s3api put-bucket-replication \
  --bucket epermit-terraform-state-prod \
  --replication-configuration '{
    "Role": "arn:aws:iam::ACCOUNT_ID:role/s3-replication-role",
    "Rules": [{
      "Status": "Enabled",
      "Destination": {
        "Bucket": "arn:aws:s3:::epermit-terraform-state-prod-dr-euwest1",
        "StorageClass": "STANDARD"
      }
    }]
  }'
```

Every write to the state file in `us-east-1` is automatically and continuously replicated to `eu-west-1`. Bucket versioning (already enabled) means every previous state version is also replicated.

**Step 2 — Replicate the DynamoDB Lock Table**

Enable [DynamoDB Global Tables](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/GlobalTables.html) on `epermit-terraform-locks` to add `eu-west-1` as a replica region. This ensures the lock mechanism works in the DR region without any manual setup at failover time.

---

#### During a disaster — Failover execution

**Step 3 — Confirm `us-east-1` is unreachable**

Before acting, verify the outage is real and not a transient API error. Check the [AWS Service Health Dashboard](https://health.aws.amazon.com/health/status).

**Step 4 — Acquire the latest replicated state**

The S3 replication job may have been mid-flight when the region went down. Identify the most recent complete state object version in the DR bucket:

```bash
aws s3api list-object-versions \
  --bucket epermit-terraform-state-prod-dr-euwest1 \
  --prefix global/epermit/terraform.tfstate \
  --region eu-west-1
```

Pick the most recent `LastModified` version. Download it locally as a backup:

```bash
aws s3api get-object \
  --bucket epermit-terraform-state-prod-dr-euwest1 \
  --key global/epermit/terraform.tfstate \
  --version-id <VERSION_ID> \
  --region eu-west-1 \
  terraform.tfstate.backup
```

**Step 5 — Inspect the state file before any apply**

```bash
terraform state list
```

Verify the state reflects what was deployed in `us-east-1`. Do not proceed if the state looks incomplete or corrupted.

**Step 6 — Reconfigure the Terraform backend to point to `eu-west-1`**

Update `terraform/main.tf` backend block:

```hcl
backend "s3" {
  bucket         = "epermit-terraform-state-prod-dr-euwest1"  # DR bucket
  key            = "global/epermit/terraform.tfstate"
  region         = "eu-west-1"                                 # ← changed
  encrypt        = true
  dynamodb_table = "epermit-terraform-locks"                   # Global Table replica
}
```

Reinitialise Terraform to switch backends:

```bash
terraform init -reconfigure
```

**Step 7 — Override region variables and plan**

```bash
terraform plan \
  -var="aws_region=eu-west-1" \
  -var="availability_zones=[\"eu-west-1a\",\"eu-west-1b\"]" \
  -var="public_subnet_cidrs=[\"10.0.1.0/24\",\"10.0.2.0/24\"]" \
  -var="private_subnet_cidrs=[\"10.0.11.0/24\",\"10.0.12.0/24\"]"
```

Carefully review the plan output. Because the old resources were in `us-east-1` (which is down), Terraform will correctly detect they are unreachable and plan to **create new** resources in `eu-west-1`. This is expected and correct — you are building a fresh stack in the new region.

**Step 8 — Apply to the DR region**

```bash
terraform apply \
  -var="aws_region=eu-west-1" \
  -var="availability_zones=[\"eu-west-1a\",\"eu-west-1b\"]" \
  ...
```

Infrastructure is now live in `eu-west-1`. The state file in the DR bucket is updated atomically.

---

#### After recovery

**Step 9 — Do NOT touch `us-east-1` state until the region is confirmed stable**

When `us-east-1` recovers, the original state bucket will still contain the old state. Do not run `terraform apply` against it — this would create duplicate infrastructure. 

Decide on one of two paths:
- **Migrate back:** `terraform state mv` commands to re-reconcile state, then migrate the backend back to `us-east-1`.
- **Stay in `eu-west-1`:** Update DNS, decommission `us-east-1` resources manually (or with a targeted `terraform destroy`), and treat `eu-west-1` as the new primary.

---

### Why This Works — Key Principles

| Mechanism | Why It Matters |
|---|---|
| **S3 Versioning** | Every state write is a new version. Rolling back to a known-good state is a single `get-object --version-id` call. |
| **S3 Cross-Region Replication** | State is continuously mirrored. DR failover uses data seconds old, not hours. |
| **DynamoDB Global Tables** | The distributed lock prevents two operators from running `apply` simultaneously during a chaotic failover — the most common cause of state corruption. |
| **Immutable image tags** (pipeline) | Docker images tagged by commit SHA mean the exact binary that ran in `us-east-1` is pulled into `eu-west-1` without a rebuild. |
| **`terraform plan` before `apply`** | The plan step is a mandatory sanity check. Never skip it during DR — what Terraform intends to do must be reviewed by a human before resources are created. |

---

*Prepared for Qualisys Consulting DevOps Assessment v1.0 — 2026*
