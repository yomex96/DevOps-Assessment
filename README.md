# Zero-Trust E-Permit Infrastructure

> **Qualisys Consulting DevOps Assessment** — Production-grade IaC, containerisation, and CI/CD for a government E-Permit microservice.

---

## Repository Structure

```
DevOps-Assessment/
├── .dockerignore                       # Prevents secrets/junk entering Docker build context
├── .gitignore                          # Prevents state files, .env, tfvars from being committed
├── .github/
│   └── workflows/
│       └── pipeline.yml                # Task 3 — CI/CD pipeline
├── Dockerfile                          # Task 1 — Hardened, multi-stage image
├── package.json                        # Node.js app manifest (zero external dependencies)
├── package-lock.json                   # Lockfile required by npm ci
├── src/
│   └── index.js                        # Minimal Node.js app with /health endpoint
├── README.md
└── terraform/
    ├── providers.tf                    # terraform{} block, S3 backend, AWS provider
    ├── main.tf                         # Root orchestrator (module calls only)
    ├── variables.tf                    # All input variables (no hardcoded values)
    ├── outputs.tf                      # Root outputs
    ├── terraform.tfvars.example        # Safe template — real .tfvars is gitignored
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
| Ran as `root` | Dedicated system user/group `appuser:appgroup` (UID/GID 1001); `USER appuser` before `CMD` |
| Fat image — devDependencies included | 4-stage build: `base` → `deps` (prod only) + `build` (parallel) → `runner` (clean final image) |
| Cache-busting on every code change | `COPY package.json package-lock.json ./` before `RUN npm ci` — deps layer only rebuilds when manifests change |
| No BuildKit mount cache | `--mount=type=cache,target=/root/.npm` — npm tarballs cached on BuildKit daemon, not re-downloaded on every build |
| `curl` in the runtime image | Removed entirely — HEALTHCHECK uses Node.js built-in `http` module, zero extra packages |
| Files owned by root after COPY | All `COPY` instructions use `--chown=appuser:appgroup` — no extra `RUN chown` layer |
| `postinstall` script risk | `--ignore-scripts` on `npm ci` prevents malicious lifecycle hooks from executing |

### Multi-Stage Parallel Build

BuildKit automatically executes `deps` and `build` stages in parallel since they share the same `base` but do not depend on each other:

```
base
 ├── deps   (npm ci --omit=dev)     ┐
 └── build  (npm ci + npm run build)├──► runner (final image)
            parallel ───────────────┘
```

### Healthcheck Without curl

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD node -e "require('http').get('http://localhost:3000/health', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"
```

Uses the Node.js runtime already present in the image — installing `curl` would add an unnecessary binary and introduce CVEs to the runtime image.

---

## Task 2 — Terraform Initialisation Guide

### Prerequisites

- [Terraform ≥ 1.7](https://developer.hashicorp.com/terraform/install)
- AWS CLI configured (`aws configure`) with permissions to create VPC, IAM, and S3 resources
- An S3 bucket and DynamoDB table for remote state (see Step 0)

### Step 0 — Bootstrap Remote State (one-time, manual)

The S3 backend resources must exist before `terraform init` can run. Create them once:

```bash
# Create the state bucket — versioning is mandatory for point-in-time recovery
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

# Block all public access — state must never be public
aws s3api put-public-access-block \
  --bucket epermit-terraform-state-prod \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Create the DynamoDB lock table — prevents concurrent state corruption
aws dynamodb create-table \
  --table-name epermit-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### Step 1 — Copy and fill tfvars

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

# Or override variables for DR failover to eu-west-1
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

Type `yes` when prompted. Terraform provisions the VPC, subnets, NAT Gateways, IAM role, and instance profile.

### Step 5 — Verify Outputs

```bash
terraform output
```

Key outputs: `vpc_id`, `public_subnet_ids`, `private_subnet_ids`, `ec2_instance_profile_name`, `ec2_role_arn`.

### Step 6 — Destroy (cleanup)

```bash
terraform destroy
```

---

## Task 2 — Infrastructure Design Decisions

### VPC Module

| Design Choice | Rationale |
|---|---|
| One NAT Gateway per AZ | Eliminates NAT as a single point of failure — if one AZ's NAT fails, the other AZ's private subnets still have outbound internet |
| Private route tables per AZ | Each private subnet routes through its local NAT Gateway — AZ failure is contained |
| `count` with `length(var.availability_zones)` | Adding a third AZ requires only a new CIDR in the variable — no code changes |
| All values parameterised | Region, AZ list, CIDRs, environment — nothing hardcoded |

### IAM Module (Least Privilege)

The role enforces two independent layers:

1. **Allow Policy** — `s3:ListBucket` and `s3:GetObject` only on `epermit-secure-documents-prod`
2. **Explicit Deny** — `s3:*` denied on all resources that are NOT the allowed bucket

```
IAM Evaluation: Does the request match an explicit Deny? → YES → DENIED
(Explicit Deny overrides any accidental Allow — including AWS-managed policies attached by mistake)
```

---

## Task 3 — CI/CD Pipeline

### GitHub Secrets Required

Configure in **Settings → Secrets and variables → Actions**:

| Secret | Description |
|---|---|
| `AWS_ECR_REGISTRY` | ECR registry URI — used in simulate steps (masked in logs) |
| `AWS_ECR_REPOSITORY` | ECR repository name — used in simulate steps (masked in logs) |
| `AWS_REGION` | Target region — used in simulate steps (masked in logs) |

> **Production Upgrade:** Replace the simulated steps with GitHub OIDC federation into an IAM Role. This eliminates all long-lived static credentials — GitHub Actions federates directly into AWS with no secrets stored in the repository.

### Zero-Trust Hardening Applied to the Pipeline

| Control | Implementation |
|---|---|
| Trivy called directly | Trivy binary installed and called via `run:` — no action wrapper that could silently override `--ignore-unfixed` or `--exit-code` flags |
| Security gate before push | `--exit-code 1` fails the job — image is **never pushed** if a fixable CRITICAL CVE exists |
| `--ignore-unfixed` | Only CVEs with available patches trigger failure — CVEs with no fix are excluded (not actionable) |
| Immutable image tags | Images tagged with `${{ github.sha }}` — every build is traceable to an exact commit |
| SARIF report artifact | Scan results uploaded as a build artifact — persistent audit trail even when the pipeline fails |
| Simulated credentials | ECR login and push are simulated via `echo` — no real AWS credentials needed or stored |

### Pipeline Flow

```
push to main
     │
     ▼
┌─────────────────────────────────┐
│  1. Checkout repository         │
└─────────────┬───────────────────┘
              │
              ▼
┌─────────────────────────────────┐
│  2. Build Docker image          │
│     docker build -t             │
│     epermit-api:${{ sha }}      │
└─────────────┬───────────────────┘
              │
              ▼
┌─────────────────────────────────┐
│  3. Install Trivy               │
│     (official install script)   │
└─────────────┬───────────────────┘
              │
              ▼
┌─────────────────────────────────┐  ← SECURITY GATE
│  4. Trivy Security Scan         │
│     --severity CRITICAL         │
│     --ignore-unfixed            │
│     --exit-code 1               │
│  *** PIPELINE FAILS HERE ***    │
│  if fixable CRITICAL CVEs found │
└─────────────┬───────────────────┘
              │  (only continues if scan passes)
              ▼
┌─────────────────────────────────┐
│  5. Generate SARIF report       │  if: always() — audit trail
│     Upload as build artifact    │  even when pipeline fails
└─────────────┬───────────────────┘
              │
              ▼
┌─────────────────────────────────┐
│  6. Simulate ECR Login          │  Secrets masked in logs
└─────────────┬───────────────────┘
              │
              ▼
┌─────────────────────────────────┐
│  7. Simulate Docker Push        │  Tagged with commit SHA
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

Configure this once after the bootstrap step. Every write to the state file in `us-east-1` is automatically replicated to `eu-west-1`:

```bash
# Create the DR replica bucket
aws s3api create-bucket \
  --bucket epermit-terraform-state-prod-dr-euwest1 \
  --create-bucket-configuration LocationConstraint=eu-west-1 \
  --region eu-west-1

aws s3api put-bucket-versioning \
  --bucket epermit-terraform-state-prod-dr-euwest1 \
  --versioning-configuration Status=Enabled

# Configure replication from us-east-1 → eu-west-1
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

**Step 2 — Replicate the DynamoDB Lock Table**

Enable [DynamoDB Global Tables](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/GlobalTables.html) to add `eu-west-1` as a replica:

```bash
aws dynamodb create-global-table \
  --global-table-name epermit-terraform-locks \
  --replication-group RegionName=eu-west-1 \
  --region us-east-1
```

This ensures the distributed lock works in the DR region immediately — no manual setup required at failover time. Without it, two operators running `terraform apply` simultaneously during a chaotic failover is the most common cause of state corruption.

---

### During a Disaster — Failover Execution

**Step 3 — Confirm `us-east-1` is unreachable**

Verify the outage is real — not a transient API error. Check the [AWS Service Health Dashboard](https://health.aws.amazon.com/health/status). A transient error that self-resolves while a failover is mid-flight is the scenario most likely to produce state corruption.

**Step 4 — Identify the latest replicated state version**

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

**Step 5 — Inspect the state before any apply**

```bash
terraform state list
```

Verify the state reflects what was deployed in `us-east-1`. Do not proceed if the state looks incomplete or corrupted.

**Step 6 — Reconfigure the Terraform backend to `eu-west-1`**

Update the `backend "s3"` block in `terraform/providers.tf`:

```hcl
backend "s3" {
  bucket         = "epermit-terraform-state-prod-dr-euwest1"  # DR bucket
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

**Step 7 — Plan against the DR region**

```bash
terraform plan \
  -var="aws_region=eu-west-1" \
  -var="availability_zones=[\"eu-west-1a\",\"eu-west-1b\"]" \
  -var="public_subnet_cidrs=[\"10.0.1.0/24\",\"10.0.2.0/24\"]" \
  -var="private_subnet_cidrs=[\"10.0.11.0/24\",\"10.0.12.0/24\"]"
```

Review the plan carefully. Terraform correctly detects the `us-east-1` resources are unreachable and plans to create new resources in `eu-west-1`. This is expected — a fresh stack in the new region.

**Step 8 — Apply to the DR region**

```bash
terraform apply \
  -var="aws_region=eu-west-1" \
  -var="availability_zones=[\"eu-west-1a\",\"eu-west-1b\"]" \
  -var="public_subnet_cidrs=[\"10.0.1.0/24\",\"10.0.2.0/24\"]" \
  -var="private_subnet_cidrs=[\"10.0.11.0/24\",\"10.0.12.0/24\"]"
```

Infrastructure is now live in `eu-west-1`. The state file in the DR bucket is updated atomically.

---

### After Recovery

**Step 9 — Do NOT touch `us-east-1` state until the region is confirmed stable**

When `us-east-1` recovers, the original state bucket still contains the old state reflecting resources that no longer exist. Running `terraform apply` against it would create duplicate infrastructure.

Choose one path:

- **Stay in `eu-west-1` (recommended):** Update DNS, decommission `us-east-1` resources with a targeted `terraform destroy`, and treat `eu-west-1` as the new primary.
- **Migrate back to `us-east-1`:** Use `terraform state mv` to reconcile state entries, destroy `eu-west-1` resources, and migrate the backend back. This is operationally more complex and riskier during a recovery window.

---

### Why This Works — Key Principles

| Mechanism | Why It Matters |
|---|---|
| **S3 Versioning** | Every state write is a new immutable version. Rolling back to a known-good state is a single `get-object --version-id` call. No state is ever permanently lost. |
| **S3 Cross-Region Replication** | State is continuously mirrored. DR failover uses data seconds old, not hours. |
| **DynamoDB Global Tables** | The distributed lock prevents two operators from running `apply` simultaneously during a chaotic failover — the most common cause of state corruption. |
| **Immutable image tags** | Docker images tagged by commit SHA mean the exact binary that ran in `us-east-1` can be pulled into `eu-west-1` without a rebuild. |
| **`terraform plan` before `apply`** | Mandatory sanity check during DR. Never skip it — what Terraform intends to do must be reviewed by a human before resources are created. |
| **Region passed as variable** | The AWS provider region is a variable, not hardcoded. The same Terraform code targets `eu-west-1` with a single `-var` flag — no file edits during an outage. |


### Author : Abayomi Robert Onawole
---

*Prepared for Qualisys Consulting DevOps Assessment v1.0 — 2026*
