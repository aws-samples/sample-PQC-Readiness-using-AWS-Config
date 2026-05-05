#!/bin/bash

# PQC Scanner - Build, Package, and Prepare for StackSets Deployment
# Builds Lambda functions, creates ZIP packages, uploads to S3, and generates
# a resolved CloudFormation template (packaged-template.yaml) ready for StackSets.
#
# Usage: ./deploy-stacksets.sh <s3-bucket>
# Example: ./deploy-stacksets.sh my-org-shared-bucket

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_section() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

# Validate inputs
if [ $# -lt 1 ]; then
    echo "Usage: $0 <s3-bucket>"
    echo ""
    echo "Arguments:"
    echo "  s3-bucket    S3 bucket name for Lambda deployment packages"
    echo ""
    echo "Examples:"
    echo "  $0 my-org-shared-bucket"
    echo ""
    echo "This script:"
    echo "  1. Builds Lambda functions using SAM"
    echo "  2. Creates ZIP packages"
    echo "  3. Uploads ZIPs to S3"
    echo "  4. Generates packaged-template.yaml with S3 values baked in"
    echo ""
    echo "After running, use packaged-template.yaml with create-stack-set (no parameters needed)."
    exit 1
fi

S3_BUCKET=$1
ELB_S3_KEY="pqc-scanner/elb-pqc.zip"
APIGW_S3_KEY="pqc-scanner/api-gateway-pqc.zip"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

print_section "PQC Scanner - StackSets Package Builder"
echo "S3 Bucket:     $S3_BUCKET"
echo "ELB ZIP Key:   $ELB_S3_KEY"
echo "APIGW ZIP Key: $APIGW_S3_KEY"
echo ""

# Step 1: Build Lambda functions
print_info "Step 1: Building Lambda functions..."
cd "$PROJECT_ROOT/installation"
sam build
print_info "✅ SAM build complete"

# Step 2: Create ZIP packages
print_info "Step 2: Creating ZIP packages..."
cd "$PROJECT_ROOT/installation/.aws-sam/build"

rm -f elb-pqc.zip api-gateway-pqc.zip
zip -j elb-pqc.zip ELBComplianceFunction/*
zip -j api-gateway-pqc.zip APIGatewayComplianceFunction/*

print_info "✅ ZIP packages created"
print_info "   elb-pqc.zip: $(du -h elb-pqc.zip | cut -f1)"
print_info "   api-gateway-pqc.zip: $(du -h api-gateway-pqc.zip | cut -f1)"

# Step 3: Upload to S3
print_info "Step 3: Uploading ZIP packages to S3..."
aws s3 cp elb-pqc.zip "s3://${S3_BUCKET}/${ELB_S3_KEY}"
aws s3 cp api-gateway-pqc.zip "s3://${S3_BUCKET}/${APIGW_S3_KEY}"
print_info "✅ Uploaded to s3://${S3_BUCKET}/pqc-scanner/"

# Step 4: Generate resolved packaged-template.yaml
print_info "Step 4: Generating packaged-template.yaml with baked-in S3 values..."

cd "$SCRIPT_DIR"
sed -e "s|__LAMBDA_CODE_BUCKET__|${S3_BUCKET}|g" \
    -e "s|__ELB_LAMBDA_CODE_KEY__|${ELB_S3_KEY}|g" \
    -e "s|__APIGW_LAMBDA_CODE_KEY__|${APIGW_S3_KEY}|g" \
    packaged-template.yaml.tpl > packaged-template.yaml

print_info "✅ Generated: installation/packaged-template.yaml"

# Done
print_section "Package Complete"
echo "Next steps:"
echo ""
echo "1. Create StackSet (from management/delegated admin account):"
echo "   aws cloudformation create-stack-set \\"
echo "     --stack-set-name pqc-readiness-lambda-functions \\"
echo "     --template-body file://installation/packaged-template.yaml \\"
echo "     --capabilities CAPABILITY_IAM \\"
echo "     --permission-model SERVICE_MANAGED \\"
echo "     --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \\"
echo "     --region us-east-1"
echo ""
echo "2. Deploy to accounts (--regions = target deployment regions, --region = StackSet home region):"
echo "   aws cloudformation create-stack-instances \\"
echo "     --stack-set-name pqc-readiness-lambda-functions \\"
echo "     --deployment-targets OrganizationalUnitIds=<ou-id> \\"
echo "     --regions us-east-1 \\"
echo "     --region us-east-1"
echo ""
echo "3. Deploy organization conformance pack:"
echo "   aws configservice put-organization-conformance-pack \\"
echo "     --organization-conformance-pack-name pqc-legacy-tls-compliance \\"
echo "     --template-body file://conformance-packs/pqc-legacy-tls-conformance-pack.yaml \\"
echo "     --region us-east-1"
echo ""
