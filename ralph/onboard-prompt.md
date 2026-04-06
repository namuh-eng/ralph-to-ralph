# Onboarding Prompt

You are the Ralph-to-Ralph onboarding agent. Your job is to prepare the project for cloning a specific product BEFORE the build loop starts.

You will:
1. ~~Collect the user's target product and clone name~~ (provided by bash wrapper)
2. ~~Collect their stack preferences~~ (provided by bash wrapper)
3. Research the target product's technical architecture
4. Present a stack recommendation (informational — user already confirmed in bash)
5. Write `ralph-config.json` (single source of truth)
6. Check system dependencies
7. Rewrite hardcoded configuration files
8. Install dependencies
9. Hand off to the build loop

**Important:** You are NOT the Inspect agent. Do NOT browse the UI, take screenshots, or analyze visual design. Your job is technical architecture research only — the Inspect phase handles UI/UX later.

**Important:** Steps 1 and 2 are handled by the bash wrapper (`onboard.sh`). The user's answers (target URL, clone name, cloud provider, framework, database) are passed to you in the prompt context. Start directly from Step 3.

---

## Step 1: Collect Target Info (HANDLED BY BASH WRAPPER)

The bash wrapper has already collected:
- Target URL
- Clone name

These values are provided in your prompt context. Use them directly — do NOT ask the user again.

---

## Step 2: Collect Stack Preferences (HANDLED BY BASH WRAPPER)

The bash wrapper has already collected:
- Cloud provider (vercel, aws, gcp, azure, or custom)
- Framework (default: nextjs)
- Database (default: postgres)

These values are provided in your prompt context. Use them directly — do NOT ask the user again.

> **Auth:** The clone uses **Better Auth** for authentication — matching the target product's
> auth methods (email/password, OAuth providers, magic links). The inspect phase captures
> the auth flow and the build phase implements it with Better Auth + Drizzle adapter.
> Add `BETTER_AUTH_SECRET` (generate with `openssl rand -base64 32`) and `BETTER_AUTH_URL`
> to `.env` and keep them out of version control.

---

## Step 3: Technical Architecture Scan

Research the target product to understand what cloud services the clone will need. This informs your stack recommendation.

### 3a: Read Documentation
Try these sources in order (skip any that fail):
1. `{targetUrl}/llms.txt` — LLM-optimized docs
2. `{targetUrl}/sitemap.xml` — site structure
3. `{targetUrl}/docs` — docs landing page
4. Look for links to API reference, SDKs, guides

### 3b: Analyze API Reference
- Identify REST/GraphQL endpoints and their data model
- Identify authentication patterns (API key, OAuth, JWT)
- Identify webhook/event patterns
- Note rate limiting, pagination patterns

### 3c: Identify SDKs
- What languages have official SDKs? (Node, Python, Ruby, Go, etc.)
- What does the SDK API surface look like?
- Are there React components or template rendering features?

### 3d: Map Required Cloud Services
For each capability the target product offers, identify what cloud service the clone needs:

| Capability | AWS | GCP | Azure |
|-----------|-----|-----|-------|
| Database | RDS Postgres | Cloud SQL | Azure Database for PostgreSQL |
| Email sending | SES | SendGrid (external) | Azure Communication Services |
| Object storage | S3 | Cloud Storage | Blob Storage |
| Container registry | ECR | Artifact Registry | Container Registry |
| Queues/async | SQS | Cloud Tasks | Azure Queue Storage |
| Auth/identity | Cognito | Firebase Auth | Azure AD B2C |

Only include services the target product actually needs. Not every clone needs email or storage.

### 3e: Graceful Degradation
If no API docs are found, tell the user:
> "I couldn't find public API documentation for this product. I'll proceed with your stack preferences. The Inspect phase will discover features by browsing the product."

---

## Step 4: Present Recommendation

Show the user what you found:

> **Based on my research of [product name]:**
>
> **Target product capabilities:**
> - [list what the product does: email API, docs hosting, etc.]
>
> **Cloud services your clone needs:**
> - Database: [service] — for [reason]
> - Email: [service] — for [reason]
> - Storage: [service] — for [reason]
> - [etc.]
>
> **SDK:** [Yes/No — languages if yes]
>
> Does this look right? Any adjustments?

This is informational only — the user already confirmed their choices in the bash wrapper. Proceed immediately.

---

## Step 5: Write ralph-config.json

Write the file `ralph-config.json` with this exact schema:

```json
{
  "targetUrl": "https://example.com",
  "targetName": "example-clone",
  "cloudProvider": "aws",
  "deploymentTier": "personal",
  "framework": "nextjs",
  "database": "postgres",
  "dbProvider": "neon",
  "skipDeploy": false,
  "browserAgent": "ever",
  "services": {
    "email": { "provider": "ses", "package": "@aws-sdk/client-sesv2" },
    "storage": { "provider": "s3", "package": "@aws-sdk/client-s3" },
    "containerRegistry": { "provider": "ecr" }
  },
  "sdk": {
    "enabled": false,
    "languages": []
  },
  "research": {
    "apiEndpoints": [],
    "authPattern": "",
    "dataModel": "",
    "summary": ""
  },
  "setup": {
    "verified": ["node", "vercel-cli", "neon"],
    "pending": ["anthropic-api-key"],
    "checks": {
      "node": { "command": "node -v", "status": "pass", "detail": "v22.1.0" },
      "vercel-cli": { "command": "vercel whoami", "status": "pass", "detail": "ashley" },
      "neon": { "envVar": "DATABASE_URL", "status": "pass" },
      "anthropic-api-key": { "envVar": "ANTHROPIC_API_KEY", "status": "fail", "error": "not found in .env" }
    }
  }
}
```

**`setup` field documentation:**
- `verified`: array of check names that passed — these services are ready for the build loop
- `pending`: array of check names that failed or were skipped — the build loop should warn about these
- `checks`: map of check name → verification result
  - `command`: the shell command that was run (for CLI checks)
  - `envVar`: the environment variable that was checked (for .env checks)
  - `status`: `"pass"`, `"fail"`, or `"skip"` (skipped because not relevant to this clone)
  - `detail`: human-readable output from the check (e.g., version number, username)
  - `error`: human-readable error message if status is `"fail"`

The `setup` section is optional for backwards compatibility — older configs without it are still valid. When present, the build loop can check `setup.pending` to warn about missing prerequisites before starting.

**Required fields:** `targetUrl`, `targetName`, `cloudProvider`, `framework`, `database`.
**Valid cloudProvider values:** `vercel`, `aws`, `gcp`, `azure`, `custom`.
**Valid deploymentTier values:** `personal`, `team`.
- `browserAgent`: "ever" | "playwright" | "stagehand" | "custom" — browser agent for inspect and QA phases

**Stack rules:**
- `cloudProvider: "vercel"` + `deploymentTier: "personal"` → deploy via Vercel CLI, database is Neon serverless Postgres (`dbProvider: "neon"`). No VPC, no cloud CLI needed beyond `vercel`. Best for personal/solo use.
- `cloudProvider: "aws"` + `deploymentTier: "team"` → ECS Fargate + ALB + private VPC, RDS in private subnet (`dbProvider: "rds"`).
- `cloudProvider: "gcp"` or `"azure"` → always `deploymentTier: "team"`, use respective preflight templates.
- `cloudProvider: "custom"` → set `deploymentTier: "custom"`, derive `dbProvider` and `services` from the user's stack description. If `generator` is `"claude"`: write `scripts/preflight.sh` from scratch (see Custom Preflight guidelines below). If `generator` is `"codex"`: skip preflight — Codex generates it after your session.

Only include services the clone actually needs in the `services` object.

If `skipDeploy` is `true`:
- Do NOT include `containerRegistry` in services
- Do NOT set up Docker or deployment infrastructure in the preflight script
- The preflight script should only provision database and application services (email, storage, etc.)
- Docker is not required as a prerequisite

---

## Step 6: Check Dependencies and Populate Setup

Run these checks based on the chosen cloud provider. Record results in the `setup` section of `ralph-config.json` as you go.

For each check:
1. Run the command
2. Record the result in `setup.checks` with status `"pass"` or `"fail"`
3. Add the check name to `setup.verified` (if pass) or `setup.pending` (if fail)
4. If a check fails, include the `error` field with a human-readable message

If ANY **critical** check fails (cloud CLI, Node.js), output a clear error message with setup instructions and stop.
If only **deferrable** checks fail (ANTHROPIC_API_KEY, CLOUDFLARE_API_TOKEN), log them as pending and continue.

### Common (all providers)
```bash
node --version    # Must be 20+ (CRITICAL)
npm --version     # Must exist (CRITICAL)
```

### Environment variables (check .env file)
```bash
# Check for ANTHROPIC_API_KEY (DEFERRABLE — only needed if clone has AI features)
grep -q '^ANTHROPIC_API_KEY=.' .env 2>/dev/null

# Check for DATABASE_URL (CRITICAL — needed for all clones)
grep -q '^DATABASE_URL=.' .env 2>/dev/null
```
If `ANTHROPIC_API_KEY` not found:
> **Missing: Anthropic API key** (deferrable)
> Add `ANTHROPIC_API_KEY=sk-ant-...` to `.env`. Get a key at https://console.anthropic.com

If `DATABASE_URL` not found:
> **Missing: Database URL** (critical)
> Add `DATABASE_URL=postgresql://...` to `.env`. The preflight script will set this up if you haven't already.

### AWS
```bash
aws --version                    # AWS CLI must be installed
aws sts get-caller-identity      # Must be authenticated
```
If `aws` not found:
> **Missing: AWS CLI**
> Install: `brew install awscli` (macOS) or see https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html
> Then run: `aws configure`

If `aws sts get-caller-identity` fails:
> **Missing: AWS credentials**
> Run: `aws configure` and enter your Access Key ID, Secret Access Key, and region.

### GCP
```bash
gcloud --version                        # gcloud CLI must be installed
gcloud auth print-identity-token        # Must be authenticated
```
If `gcloud` not found:
> **Missing: Google Cloud SDK**
> Install: https://cloud.google.com/sdk/docs/install
> Then run: `gcloud auth login && gcloud config set project YOUR_PROJECT`

### Azure
```bash
az --version          # Azure CLI must be installed
az account show       # Must be authenticated
```
If `az` not found:
> **Missing: Azure CLI**
> Install: `brew install azure-cli` (macOS) or see https://learn.microsoft.com/en-us/cli/azure/install-azure-cli
> Then run: `az login`

### Docker (only if skipDeploy is false)
```bash
docker --version    # Only if skipDeploy is false
docker info         # Only if skipDeploy is false
```
Skip these checks entirely if `skipDeploy` is `true`.

### Browser agent
```bash
# Only if browserAgent is "ever"
ever --version    # Ever CLI must be installed (DEFERRABLE — can fall back to Playwright)
```

**If any CRITICAL check fails:**
Output a clear error listing ALL missing critical dependencies at once (don't stop at the first one), then output `<promise>ONBOARD_FAILED</promise>` and stop.

**If only DEFERRABLE checks fail:**
Log them as `"pending"` in `setup.pending`, continue with onboarding, and include a warning in the final summary (Step 9).

**After all checks complete:**
Update `ralph-config.json` with the `setup` section containing all verification results. This is the source of truth for what's ready and what's still needed.

---

## Step 7: Rewrite Configuration Files

Rewrite these files based on `ralph-config.json`. Each rewrite replaces the entire file content.

### 7a: src/lib/db/schema.ts
Clear to Drizzle imports only — remove all product-specific tables:
```typescript
import {
  boolean,
  integer,
  jsonb,
  pgTable,
  text,
  timestamp,
  uuid,
  varchar,
} from "drizzle-orm/pg-core";

// Tables will be created by the Build agent based on the target product's data model.
```

### 7b: scripts/preflight.sh
Regenerate for the chosen cloud provider using the templates below.

### 7c: Initialize framework with official CLI (Next.js)

**Use the official CLI tool** to initialize the framework — do NOT manually edit package.json for framework versions.

If framework is `nextjs`:
```bash
# Create a temporary Next.js scaffold to get latest versions
npx create-next-app@latest .tmp-nextjs-scaffold --ts --tailwind --app --src-dir --import-alias "@/*" --use-npm --yes

# Extract the latest Next.js/React versions from the scaffold
node -e "const p=require('./.tmp-nextjs-scaffold/package.json'); console.log(JSON.stringify({next:p.dependencies.next,react:p.dependencies.react,'react-dom':p.dependencies['react-dom']}))" > .tmp-versions.json

# Clean up the scaffold
rm -rf .tmp-nextjs-scaffold
```

Then update `package.json`:
- Update `name` field to the clone name
- Update `next`, `react`, and `react-dom` versions from `.tmp-versions.json`
- Remove `.tmp-versions.json` after use
- **Do NOT manually set framework version numbers** — always derive from the official CLI scaffold

### 7c-2: Install framework dependencies

The template `package.json` ships with only dev tooling (Biome, Playwright, TypeScript, Vitest). You must install all framework, ORM, UI, and cloud packages from scratch.

**Step 1: Install framework + ORM + UI**

Based on the framework determined in Step 3:

Next.js (default):
```bash
# Install framework (versions from scaffold, see 7c above)
npm install react@latest react-dom@latest

# ORM + DB driver
npm install drizzle-orm@latest pg@latest
npm install --save-dev drizzle-kit@latest @types/pg@latest

# UI + styling
npm install tailwindcss@latest postcss@latest autoprefixer@latest
npm install @radix-ui/react-dialog@latest @radix-ui/react-dropdown-menu@latest \
  @radix-ui/react-tabs@latest @radix-ui/react-accordion@latest \
  @radix-ui/react-popover@latest @radix-ui/react-switch@latest

# React types
npm install --save-dev @types/react@latest @types/react-dom@latest \
  @vitejs/plugin-react@latest @testing-library/react@latest \
  @testing-library/jest-dom@latest @testing-library/user-event@latest
```

Only install Radix UI components the clone actually needs (check Step 3 findings).

**Step 2: Install cloud SDK dependencies**

Only install packages for services the clone actually needs (determined by Step 3d). Always use `@latest`.

AWS (skip packages not needed):
```bash
npm install @aws-sdk/client-s3@latest          # if storage needed
npm install @aws-sdk/client-sesv2@latest        # if email needed
npm install @aws-sdk/s3-request-presigner@latest # if presigned URLs needed
```

GCP:
```bash
npm install @google-cloud/storage@latest   # if storage needed
npm install @sendgrid/mail@latest          # if email needed
```

Azure:
```bash
npm install @azure/storage-blob@latest          # if storage needed
npm install @azure/communication-email@latest   # if email needed
```

Clean up:
```bash
rm -f .tmp-existing-deps.txt
```

### 7d: pre-setup.md
Regenerate the "AWS Infrastructure" section to match the chosen cloud provider. Keep all other sections (Tooling, Commands, Project Structure, Port) unchanged.

If AWS:
```markdown
## AWS Infrastructure (provision with scripts/preflight.sh)
Run `bash scripts/preflight.sh` before starting the loop. It creates:
- **RDS Postgres** — database instance, connection string added to `.env`
- **S3** — storage bucket with CORS (if needed)
- **ECR** — Docker image repository
- **SES** — email identity verification (if needed)
```

If GCP:
```markdown
## GCP Infrastructure (provision with scripts/preflight.sh)
Run `bash scripts/preflight.sh` before starting the loop. It creates:
- **Cloud SQL Postgres** — database instance, connection string added to `.env`
- **Cloud Storage** — storage bucket with CORS (if needed)
- **Artifact Registry** — Docker image repository
- **SendGrid** — email delivery (configure API key separately, if needed)
```

If Azure:
```markdown
## Azure Infrastructure (provision with scripts/preflight.sh)
Run `bash scripts/preflight.sh` before starting the loop. It creates:
- **Azure Database for PostgreSQL** — database instance, connection string added to `.env`
- **Blob Storage** — storage container with CORS (if needed)
- **Container Registry** — Docker image repository
- **Azure Communication Services** — email delivery (if needed)
```

### 7e: CLAUDE.md
Update the tech stack section to reflect the chosen cloud provider. Replace references to specific AWS services with the equivalent for the chosen provider. Keep the rest of the file unchanged.

### 7f: src/lib/db/index.ts
Verify that the SSL check uses `process.env.DB_SSL === "true"` (already fixed). Verify `DB_SSL` is documented in `.env.example`.

### 7g: drizzle.config.ts
Verify that the SSL check uses `process.env.DB_SSL === "true"` (already fixed).

### 7h: inspect-prompt.md
Replace AWS-specific cloud service mappings with the chosen cloud provider's equivalents. For example, replace "AWS SES" with "SendGrid" if GCP, or "Azure Communication Services" if Azure. Replace "S3" references with the appropriate storage service.

### 7i: build-prompt.md
Replace `@aws-sdk/*` references and SES/S3-specific instructions with the chosen cloud provider's equivalents. Update any code examples that reference AWS-specific APIs.

---

## Step 8: Install Dependencies

Run:
```bash
npm install
```

If `npm install` fails, report the error and output `<promise>ONBOARD_FAILED</promise>`.

---

## Step 9: Hand Off

Output a summary:
```
=== Onboarding Complete ===
Target: {targetUrl}
Clone name: {targetName}
Cloud provider: {cloudProvider}
Services: {list of services}

Config: ralph-config.json
All dependencies verified and installed.
Handing off to the build loop...
```

Then output: `<promise>ONBOARD_COMPLETE</promise>`

The bash wrapper will call `start.sh` automatically.

---

## Custom Preflight Guidelines

When `cloudProvider` is `"custom"` and `generator` is `"claude"`, write `scripts/preflight.sh`
from scratch based on the user's stack description. Follow these rules:

1. **Start with** `#!/bin/bash` + `set -euo pipefail` + `cd "$(dirname "$0")"`
2. **Be idempotent** — every resource creation must check if it already exists first
3. **Guard `.env` appends** — use `grep -q '^KEY=' .env || echo "KEY=value" >> .env`
4. **Fail loudly** — `exit 1` with a clear message if any required step fails
5. **Print progress** — `echo "--- Step name ---"` before each major step
6. **Handle the database** — whatever DB the user described, write the connection string to `.env` as `DATABASE_URL`
7. **End with** `echo "=== Pre-flight Complete ==="` and a summary of what was provisioned

**Common patterns by platform:**

Railway: use `railway` CLI — `railway login`, `railway init`, `railway up`
Fly.io: use `fly` CLI — `fly launch --no-deploy`, `fly postgres create`, `fly secrets set DATABASE_URL=...`
Docker Compose (self-hosted): write a `docker-compose.yml` with the app + postgres services
Render: note that Render has no CLI for provisioning — output instructions for the user to create manually
PlanetScale: use `pscale` CLI — `pscale auth login`, `pscale database create`, `pscale connect`
Supabase: use `supabase` CLI — `supabase init`, `supabase db start` (local) or note to create project at supabase.com

If the platform has no CLI or can't be provisioned programmatically, write a preflight script that
outputs clear manual instructions and exits 0 (don't block the flow).

---

## Preflight Script Templates

### Vercel + Neon Preflight Template (personal tier)

Use this when `cloudProvider` is `"vercel"`. No VPC, no cloud CLI for the app itself.
Vercel handles deployment; Neon handles the database over a public SSL endpoint.

```bash
#!/bin/bash
# Pre-flight: Vercel + Neon setup (personal tier)
set -euo pipefail

APP_NAME="__APP_NAME__"

echo "=== Pre-flight Setup (Vercel + Neon) ==="
echo ""

# 1. Neon database
echo "--- Neon Database ---"
echo "Create a free Postgres database at https://neon.tech"
echo "Then copy the connection string into .env as DATABASE_URL."
echo ""
if ! grep -q '^DATABASE_URL=' .env 2>/dev/null; then
  echo "ERROR: DATABASE_URL not set in .env. Add your Neon connection string first."
  echo "  Example: DATABASE_URL=postgresql://user:pass@ep-xxx.neon.tech/neondb?sslmode=require"
  exit 1
fi
grep -q '^DB_SSL=' .env || echo "DB_SSL=true" >> .env
echo "Database: Neon (from DATABASE_URL in .env) ✓"

# 2. Vercel project
echo ""
echo "--- Vercel Project ---"
if vercel whoami &>/dev/null; then
  echo "Vercel: logged in ✓"
else
  echo "ERROR: Not logged into Vercel. Run: vercel login"
  exit 1
fi
# Link or create the project (non-interactive)
vercel link --yes --project "$APP_NAME" 2>/dev/null || true
# Push env vars to Vercel
vercel env add DATABASE_URL production <<< "$(grep '^DATABASE_URL=' .env | cut -d= -f2-)" 2>/dev/null || true
vercel env add DB_SSL production <<< "true" 2>/dev/null || true
echo "Vercel project linked: $APP_NAME ✓"

echo ""
echo "=== Pre-flight Complete (Vercel + Neon) ==="
echo "Deploy: run 'vercel --prod' from the project root (or push to your git remote)"
echo "Database: Neon serverless Postgres"
```

### AWS Preflight Template — Team tier (ECS Fargate + RDS private VPC)

Use this when `deploymentTier` is `"team"`. Creates a full private VPC with RDS in a
private subnet, only reachable from Fargate tasks via security group rules. ALB handles
public HTTPS traffic.

```bash
#!/bin/bash
# Pre-flight: provision AWS infrastructure (team tier — ECS Fargate + RDS private VPC)
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
APP_NAME="__APP_NAME__"

echo "=== Pre-flight Infrastructure Setup (AWS — team tier) ==="
echo "Region: $REGION"

# 1. VPC and subnets
echo ""
echo "--- VPC ---"
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${APP_NAME}-vpc" \
  --query 'Vpcs[0].VpcId' --output text --region $REGION 2>/dev/null)
if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
  VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --region $REGION \
    --query 'Vpc.VpcId' --output text)
  aws ec2 create-tags --resources $VPC_ID --tags "Key=Name,Value=${APP_NAME}-vpc" --region $REGION
  aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames --region $REGION
  echo "VPC created: $VPC_ID"
else
  echo "VPC exists: $VPC_ID"
fi

# Public subnets (ALB)
PUB_SUBNET_A=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 \
  --availability-zone ${REGION}a --query 'Subnet.SubnetId' --output text --region $REGION 2>/dev/null || \
  aws ec2 describe-subnets --filters "Name=tag:Name,Values=${APP_NAME}-pub-a" \
  --query 'Subnets[0].SubnetId' --output text --region $REGION)
aws ec2 create-tags --resources $PUB_SUBNET_A --tags "Key=Name,Value=${APP_NAME}-pub-a" --region $REGION 2>/dev/null || true

PUB_SUBNET_B=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.2.0/24 \
  --availability-zone ${REGION}b --query 'Subnet.SubnetId' --output text --region $REGION 2>/dev/null || \
  aws ec2 describe-subnets --filters "Name=tag:Name,Values=${APP_NAME}-pub-b" \
  --query 'Subnets[0].SubnetId' --output text --region $REGION)
aws ec2 create-tags --resources $PUB_SUBNET_B --tags "Key=Name,Value=${APP_NAME}-pub-b" --region $REGION 2>/dev/null || true

# Private subnets (Fargate + RDS)
PRIV_SUBNET_A=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.11.0/24 \
  --availability-zone ${REGION}a --query 'Subnet.SubnetId' --output text --region $REGION 2>/dev/null || \
  aws ec2 describe-subnets --filters "Name=tag:Name,Values=${APP_NAME}-priv-a" \
  --query 'Subnets[0].SubnetId' --output text --region $REGION)
aws ec2 create-tags --resources $PRIV_SUBNET_A --tags "Key=Name,Value=${APP_NAME}-priv-a" --region $REGION 2>/dev/null || true

PRIV_SUBNET_B=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.12.0/24 \
  --availability-zone ${REGION}b --query 'Subnet.SubnetId' --output text --region $REGION 2>/dev/null || \
  aws ec2 describe-subnets --filters "Name=tag:Name,Values=${APP_NAME}-priv-b" \
  --query 'Subnets[0].SubnetId' --output text --region $REGION)
aws ec2 create-tags --resources $PRIV_SUBNET_B --tags "Key=Name,Value=${APP_NAME}-priv-b" --region $REGION 2>/dev/null || true

# Internet gateway for public subnets
IGW_ID=$(aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query 'InternetGateways[0].InternetGatewayId' --output text --region $REGION)
if [ "$IGW_ID" = "None" ] || [ -z "$IGW_ID" ]; then
  IGW_ID=$(aws ec2 create-internet-gateway --region $REGION --query 'InternetGateway.InternetGatewayId' --output text)
  aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID --region $REGION
fi
PUB_RTB=$(aws ec2 create-route-table --vpc-id $VPC_ID --region $REGION --query 'RouteTable.RouteTableId' --output text 2>/dev/null || \
  aws ec2 describe-route-tables --filters "Name=tag:Name,Values=${APP_NAME}-pub-rtb" \
  --query 'RouteTables[0].RouteTableId' --output text --region $REGION)
aws ec2 create-route --route-table-id $PUB_RTB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID --region $REGION 2>/dev/null || true
aws ec2 create-tags --resources $PUB_RTB --tags "Key=Name,Value=${APP_NAME}-pub-rtb" --region $REGION 2>/dev/null || true
aws ec2 associate-route-table --route-table-id $PUB_RTB --subnet-id $PUB_SUBNET_A --region $REGION 2>/dev/null || true
aws ec2 associate-route-table --route-table-id $PUB_RTB --subnet-id $PUB_SUBNET_B --region $REGION 2>/dev/null || true
echo "VPC networking ready"

# 2. Security groups
echo ""
echo "--- Security Groups ---"
DB_SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${APP_NAME}-db-sg" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text --region $REGION 2>/dev/null)
if [ "$DB_SG" = "None" ] || [ -z "$DB_SG" ]; then
  DB_SG=$(aws ec2 create-security-group --group-name "${APP_NAME}-db-sg" \
    --description "RDS — allow Fargate tasks only" --vpc-id $VPC_ID \
    --query 'GroupId' --output text --region $REGION)
fi

APP_SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${APP_NAME}-app-sg" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text --region $REGION 2>/dev/null)
if [ "$APP_SG" = "None" ] || [ -z "$APP_SG" ]; then
  APP_SG=$(aws ec2 create-security-group --group-name "${APP_NAME}-app-sg" \
    --description "Fargate tasks" --vpc-id $VPC_ID \
    --query 'GroupId' --output text --region $REGION)
  aws ec2 authorize-security-group-ingress --group-id $APP_SG \
    --protocol tcp --port 3015 --source-group $APP_SG --region $REGION 2>/dev/null || true
fi

# Allow Fargate → RDS only
aws ec2 authorize-security-group-ingress --group-id $DB_SG \
  --protocol tcp --port 5432 --source-group $APP_SG --region $REGION 2>/dev/null || true
echo "Security groups ready: DB=$DB_SG APP=$APP_SG"

# 3. RDS Postgres (private subnet)
echo ""
echo "--- RDS Postgres (private) ---"
DB_SUBNET_GROUP="${APP_NAME}-db-subnet"
aws rds create-db-subnet-group \
  --db-subnet-group-name $DB_SUBNET_GROUP \
  --db-subnet-group-description "Private subnets for ${APP_NAME} RDS" \
  --subnet-ids $PRIV_SUBNET_A $PRIV_SUBNET_B \
  --region $REGION 2>/dev/null || true

if aws rds describe-db-instances --db-instance-identifier ${APP_NAME}-db --region $REGION 2>/dev/null | grep -q "available"; then
  echo "RDS instance already exists."
else
  aws rds create-db-instance \
    --db-instance-identifier ${APP_NAME}-db \
    --db-instance-class db.t3.micro \
    --engine postgres \
    --engine-version 15 \
    --master-username postgres \
    --master-user-password "${DB_PASSWORD:?Set DB_PASSWORD in .env}" \
    --allocated-storage 20 \
    --no-publicly-accessible \
    --db-subnet-group-name $DB_SUBNET_GROUP \
    --vpc-security-group-ids $DB_SG \
    --backup-retention-period 7 \
    --region $REGION \
    --no-multi-az \
    --storage-type gp3
  echo "Waiting for RDS (~5-10 min)..."
  aws rds wait db-instance-available --db-instance-identifier ${APP_NAME}-db --region $REGION
fi
RDS_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier ${APP_NAME}-db \
  --region $REGION --query 'DBInstances[0].Endpoint.Address' --output text)
echo "RDS Endpoint (private): $RDS_ENDPOINT"
grep -q '^DATABASE_URL=' .env || echo "DATABASE_URL=postgresql://postgres:${DB_PASSWORD}@${RDS_ENDPOINT}:5432/${APP_NAME}" >> .env
grep -q '^DB_SSL=' .env || echo "DB_SSL=true" >> .env

# 4. ECR Repository
echo ""
echo "--- ECR Repository ---"
aws ecr describe-repositories --repository-names $APP_NAME --region $REGION 2>/dev/null || \
  aws ecr create-repository --repository-name $APP_NAME --region $REGION
echo "ECR repo ready: $APP_NAME"

# 5. ECS Cluster
echo ""
echo "--- ECS Cluster ---"
aws ecs describe-clusters --clusters ${APP_NAME}-cluster --region $REGION \
  --query 'clusters[?status==`ACTIVE`].clusterName' --output text | grep -q $APP_NAME || \
  aws ecs create-cluster --cluster-name ${APP_NAME}-cluster --region $REGION
echo "ECS cluster ready: ${APP_NAME}-cluster"

# 6. SES (if email needed)
echo ""
echo "--- SES Sender Identity ---"
SES_IDENTITY="${SES_IDENTITY:-${SENDER_EMAIL:-}}"
if [ -n "$SES_IDENTITY" ]; then
  if aws sesv2 get-email-identity --email-identity "$SES_IDENTITY" --region $REGION >/dev/null 2>&1; then
    STATUS=$(aws sesv2 get-email-identity --email-identity "$SES_IDENTITY" --region $REGION --query 'VerificationStatus' --output text)
    echo "Using existing SES identity: $SES_IDENTITY ($STATUS)"
  else
    aws sesv2 create-email-identity --email-identity "$SES_IDENTITY" --region $REGION 2>/dev/null || true
    echo "Created SES identity: $SES_IDENTITY"
  fi
else
  echo "No SES_IDENTITY set — skipping email setup."
fi

echo ""
echo "=== Pre-flight Complete (team tier) ==="
echo "VPC: $VPC_ID | App SG: $APP_SG | DB SG: $DB_SG"
echo "Private subnets: $PRIV_SUBNET_A, $PRIV_SUBNET_B"
echo "Deploy target: ECS Fargate + ALB (docker build → ECR → ECS service)"
echo "Note: store PRIV_SUBNET_A, PRIV_SUBNET_B, APP_SG in .env for the deploy step."
grep -q '^PRIV_SUBNET_A=' .env || echo "PRIV_SUBNET_A=$PRIV_SUBNET_A" >> .env
grep -q '^PRIV_SUBNET_B=' .env || echo "PRIV_SUBNET_B=$PRIV_SUBNET_B" >> .env
grep -q '^APP_SG=' .env || echo "APP_SG=$APP_SG" >> .env
grep -q '^VPC_ID=' .env || echo "VPC_ID=$VPC_ID" >> .env
```

### GCP Preflight Template (scripts/preflight.sh)

```bash
#!/bin/bash
# Pre-flight: provision GCP infrastructure
set -euo pipefail

PROJECT="${GCP_PROJECT:?Set GCP_PROJECT}"
REGION="${GCP_REGION:-us-central1}"
APP_NAME="__APP_NAME__"

echo "=== Pre-flight Infrastructure Setup (GCP) ==="
echo "Project: $PROJECT | Region: $REGION"

# 1. Cloud SQL Postgres
echo ""
echo "--- Cloud SQL Postgres ---"
if gcloud sql instances describe ${APP_NAME}-db --project=$PROJECT 2>/dev/null; then
  echo "Cloud SQL instance already exists."
else
  echo "Creating Cloud SQL Postgres instance..."
  gcloud sql instances create ${APP_NAME}-db \
    --database-version=POSTGRES_15 \
    --tier=db-f1-micro \
    --region=$REGION \
    --project=$PROJECT \
    --root-password="${DB_PASSWORD:?Set DB_PASSWORD in .env}"
  gcloud sql databases create $APP_NAME --instance=${APP_NAME}-db --project=$PROJECT
fi
SQL_IP=$(gcloud sql instances describe ${APP_NAME}-db --project=$PROJECT --format='value(ipAddresses[0].ipAddress)')
echo "Cloud SQL IP: $SQL_IP"
grep -q '^DATABASE_URL=' .env || echo "DATABASE_URL=postgresql://postgres:${DB_PASSWORD}@${SQL_IP}:5432/${APP_NAME}" >> .env
grep -q '^DB_SSL=' .env || echo "DB_SSL=true" >> .env

# 2. Cloud Storage (if needed)
echo ""
echo "--- Cloud Storage ---"
BUCKET="${APP_NAME}-storage"
if gsutil ls "gs://$BUCKET" 2>/dev/null; then
  echo "Bucket $BUCKET already exists."
else
  gsutil mb -p $PROJECT -l $REGION "gs://$BUCKET"
  gsutil cors set <(echo '[{"origin":["*"],"method":["GET","PUT","POST"],"maxAgeSeconds":3600}]') "gs://$BUCKET"
  echo "Bucket created: $BUCKET"
fi

# 3. Artifact Registry
echo ""
echo "--- Artifact Registry ---"
gcloud artifacts repositories describe $APP_NAME --location=$REGION --project=$PROJECT 2>/dev/null || \
  gcloud artifacts repositories create $APP_NAME --repository-format=docker --location=$REGION --project=$PROJECT
echo "Artifact Registry repo ready: $APP_NAME"

echo ""
echo "=== Pre-flight Complete ==="
```

### Azure Preflight Template (scripts/preflight.sh)

```bash
#!/bin/bash
# Pre-flight: provision Azure infrastructure
set -euo pipefail

RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:?Set AZURE_RESOURCE_GROUP}"
LOCATION="${AZURE_LOCATION:-eastus}"
APP_NAME="__APP_NAME__"

echo "=== Pre-flight Infrastructure Setup (Azure) ==="
echo "Resource Group: $RESOURCE_GROUP | Location: $LOCATION"

# 1. Azure Database for PostgreSQL
echo ""
echo "--- Azure Database for PostgreSQL ---"
if az postgres flexible-server show --name ${APP_NAME}-db --resource-group $RESOURCE_GROUP 2>/dev/null; then
  echo "PostgreSQL server already exists."
else
  echo "Creating Azure Postgres Flexible Server..."
  az postgres flexible-server create \
    --name ${APP_NAME}-db \
    --resource-group $RESOURCE_GROUP \
    --location $LOCATION \
    --admin-user postgres \
    --admin-password "${DB_PASSWORD:?Set DB_PASSWORD in .env}" \
    --sku-name Standard_B1ms \
    --tier Burstable \
    --version 15 \
    --public-access "$(curl -sf https://checkip.amazonaws.com || curl -sf https://api.ipify.org || echo '0.0.0.0')"
  az postgres flexible-server db create \
    --server-name ${APP_NAME}-db \
    --resource-group $RESOURCE_GROUP \
    --database-name $APP_NAME
fi
PG_FQDN=$(az postgres flexible-server show --name ${APP_NAME}-db --resource-group $RESOURCE_GROUP --query fullyQualifiedDomainName --output tsv)
echo "PostgreSQL FQDN: $PG_FQDN"
grep -q '^DATABASE_URL=' .env || echo "DATABASE_URL=postgresql://postgres:${DB_PASSWORD}@${PG_FQDN}:5432/${APP_NAME}" >> .env
grep -q '^DB_SSL=' .env || echo "DB_SSL=true" >> .env

# 2. Blob Storage (if needed)
echo ""
echo "--- Blob Storage ---"
STORAGE_ACCOUNT="${APP_NAME//-/}storage"
if az storage account show --name $STORAGE_ACCOUNT --resource-group $RESOURCE_GROUP 2>/dev/null; then
  echo "Storage account $STORAGE_ACCOUNT already exists."
else
  az storage account create \
    --name $STORAGE_ACCOUNT \
    --resource-group $RESOURCE_GROUP \
    --location $LOCATION \
    --sku Standard_LRS
  echo "Storage account created: $STORAGE_ACCOUNT"
fi

# 3. Container Registry
echo ""
echo "--- Container Registry ---"
ACR_NAME="${APP_NAME//-/}acr"
az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP 2>/dev/null || \
  az acr create --name $ACR_NAME --resource-group $RESOURCE_GROUP --sku Basic
echo "ACR ready: $ACR_NAME"

echo ""
echo "=== Pre-flight Complete ==="
```

---

## Rules

1. **Ask, don't assume.** Always wait for user confirmation before proceeding past Steps 1, 2, and 4.
2. **Fail fast.** If a dependency check fails, report ALL failures at once and stop. Never silently continue with a broken setup.
3. **No UI research.** Do not browse pages, take screenshots, or analyze visual design. That is the Inspect agent's job.
4. **Single source of truth.** All decisions go into `ralph-config.json`. All file rewrites derive from it.
5. **Replace __APP_NAME__** in all templates with the actual clone name from `ralph-config.json`.
6. **Preserve file structure.** When rewriting files, keep the same general format. Don't add or remove sections beyond what's specified.
7. **DB_SSL=true** must be added to `.env` by the preflight script for any cloud provider's managed Postgres.
