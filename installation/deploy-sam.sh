#!/bin/bash

# SAM-based PQC Readiness Config Scanner Deployment
# Simple single-account, single-region deployment

set -e

echo "🚀 SAM PQC Readiness Config Scanner Deployment"
echo "=============================================="
echo "Stack: pqc-readiness-config-scanner"
echo "Region: us-east-1"
echo ""

# Step 1: Build SAM application
echo "🔨 Step 1: Building SAM application..."
sam build
echo "  ✅ Lambda functions built and packaged"

# Step 2: Deploy SAM stack
echo ""
echo "☁️  Step 2: Deploying SAM stack..."
sam deploy --resolve-s3
echo "  ✅ PQC Readiness Config Scanner deployed"

# Step 3: Deploy conformance pack
echo ""
echo "📋 Step 3: Deploying conformance pack..."

aws configservice put-conformance-pack \
    --conformance-pack-name pqc-readiness-config-pack \
    --template-body file://conformance-packs/pqc-readiness-config-conformance-pack.yaml \
    --region us-east-1

echo "  ✅ PQC Readiness conformance pack deployed"

# Step 4: Display results
echo ""
echo "🎉 SAM Deployment Complete!"
echo "==========================="
echo ""
echo "📊 What's Deployed:"
echo "  • Enhanced ELB Lambda with 4-tier classification"
echo "  • Enhanced API Gateway Lambda with edge detection"
echo "  • AWS Config rules for real-time PQC readiness monitoring"
echo "  • Conformance pack for organizational deployment"
echo ""
echo "🔍 Next Steps:"
echo "  1. Check AWS Config console for PQC readiness results"
echo "  2. Review tier-based annotations for migration guidance"
echo "  3. Identify CRITICAL/HIGH priority resources for immediate action"
echo "  4. Plan migration: Tier 4 → Tier 3 → Tier 2 → Tier 1"
echo ""
echo "📱 AWS Config Console (us-east-1):"
echo "  https://us-east-1.console.aws.amazon.com/config/home?region=us-east-1#/rules"
echo ""
echo "📚 Documentation: README-SAM.md"
echo ""
echo "🚀 PQC Readiness Config Scanner is now active!"

# Optional: Display stack outputs
echo ""
echo "📋 Stack Outputs:"
aws cloudformation describe-stacks \
    --stack-name pqc-readiness-config-scanner \
    --region us-east-1 \
    --query 'Stacks[0].Outputs[?OutputKey==`PQCReadinessFramework`].OutputValue' \
    --output text

echo ""
echo "✅ Deployment complete! Your enhanced PQC readiness scanner is monitoring:"
echo "   • ELB/ALB/NLB listeners (4-tier classification)"
echo "   • API Gateway Regional/Private endpoints" 
echo "   • Automatic exclusion of edge-optimized APIs"
