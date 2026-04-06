#!/bin/bash
# Pre-flight: provision all AWS infrastructure BEFORE the build loop starts
# Run this once before ./ralph/ralph-watchdog.sh
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
APP_NAME="resend-clone"

echo "=== Pre-flight Infrastructure Setup ==="
echo "Region: $REGION"

# 1. RDS Postgres
echo ""
echo "--- RDS Postgres ---"
if aws rds describe-db-instances --db-instance-identifier ${APP_NAME}-db --region $REGION 2>/dev/null | grep -q "available"; then
  echo "RDS instance already exists and available."
else
  echo "Creating RDS Postgres instance..."
  aws rds create-db-instance \
    --db-instance-identifier ${APP_NAME}-db \
    --db-instance-class db.t3.micro \
    --engine postgres \
    --engine-version 15 \
    --master-username postgres \
    --master-user-password "${DB_PASSWORD:-ResendClone2026!}" \
    --allocated-storage 20 \
    --publicly-accessible \
    --backup-retention-period 0 \
    --region $REGION \
    --no-multi-az \
    --storage-type gp3 || echo "RDS creation may already be in progress"
  echo "Waiting for RDS to become available (this takes ~5-10 min)..."
  aws rds wait db-instance-available --db-instance-identifier ${APP_NAME}-db --region $REGION
fi
RDS_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier ${APP_NAME}-db --region $REGION --query 'DBInstances[0].Endpoint.Address' --output text)
echo "RDS Endpoint: $RDS_ENDPOINT"
echo "DATABASE_URL=postgresql://postgres:${DB_PASSWORD:-ResendClone2026!}@${RDS_ENDPOINT}:5432/${APP_NAME}" >> .env

# 2. SES - verify at least one sender identity for sandbox mode
echo ""
echo "--- SES Sender Identity ---"
SES_IDENTITY="${SES_IDENTITY:-${SENDER_EMAIL:-foreverbrowsing.com}}"
if aws sesv2 get-email-identity --email-identity "$SES_IDENTITY" --region $REGION >/dev/null 2>&1; then
  STATUS=$(aws sesv2 get-email-identity --email-identity "$SES_IDENTITY" --region $REGION --query 'VerificationStatus' --output text)
  echo "Using existing SES identity: $SES_IDENTITY ($STATUS)"
else
  aws sesv2 create-email-identity --email-identity "$SES_IDENTITY" --region $REGION 2>/dev/null || true
  if [[ "$SES_IDENTITY" == *"@"* ]]; then
    echo "Verification email sent to $SES_IDENTITY. Check the inbox and click the link."
  else
    echo "Created SES domain identity $SES_IDENTITY. Add the SES DNS records or use the verified demo domain foreverbrowsing.com."
  fi
fi

# 3. S3 Bucket
echo ""
echo "--- S3 Bucket ---"
BUCKET="${APP_NAME}-storage-$(aws sts get-caller-identity --query Account --output text)"
if aws s3 ls "s3://$BUCKET" 2>/dev/null; then
  echo "S3 bucket $BUCKET already exists."
else
  aws s3 mb "s3://$BUCKET" --region $REGION
  aws s3api put-bucket-cors --bucket "$BUCKET" --cors-configuration '{
    "CORSRules": [{"AllowedHeaders": ["*"], "AllowedMethods": ["GET","PUT","POST"], "AllowedOrigins": ["*"], "MaxAgeSeconds": 3600}]
  }'
  echo "S3 bucket created: $BUCKET"
fi

# 4. ECR Repository
echo ""
echo "--- ECR Repository ---"
aws ecr describe-repositories --repository-names $APP_NAME --region $REGION 2>/dev/null || \
  aws ecr create-repository --repository-name $APP_NAME --region $REGION
echo "ECR repo ready: $APP_NAME"

# 5. Summary
echo ""
echo "=== Pre-flight Complete ==="
echo "RDS: $RDS_ENDPOINT"
echo "S3: $BUCKET"
echo "ECR: $APP_NAME"
echo "SES: $SES_IDENTITY"
echo ""
echo "Next: ./ralph/ralph-watchdog.sh <target-url>"
