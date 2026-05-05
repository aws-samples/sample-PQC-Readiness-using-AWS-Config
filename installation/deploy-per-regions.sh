#!/bin/bash

# PQC Scanner Multi-Region Deployment Script
# Deploys SAM stack + conformance pack to multiple regions in one command
#
# Usage: ./deploy-all-regions.sh us-east-1 us-west-2 eu-west-1

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
STACK_NAME="pqc-readiness-config-scanner"
CONFORMANCE_PACK_NAME="pqc-legacy-tls-compliance"
MAX_WAIT_SECONDS=300  # 5 minutes timeout for conformance pack

# Functions
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_section() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

# Check if Config is enabled and recording correct resource types
check_config_prerequisites() {
    local REGION=$1
    print_info "Checking AWS Config in $REGION..."
    
    # Check if recorder exists
    RECORDER_STATUS=$(aws configservice describe-configuration-recorder-status \
        --region $REGION \
        --query 'ConfigurationRecordersStatus[0].recording' \
        --output text 2>/dev/null || echo "false")
    
    if [ "$RECORDER_STATUS" != "True" ]; then
        print_error "AWS Config is not enabled or not recording in $REGION"
        print_error "Please enable Config first: https://console.aws.amazon.com/config"
        return 1
    fi
    
    # Check recording configuration
    RECORDING_STRATEGY=$(aws configservice describe-configuration-recorders \
        --region $REGION \
        --query 'ConfigurationRecorders[0].recordingGroup.recordingStrategy.useOnly' \
        --output text 2>/dev/null)
    
    RESOURCE_TYPES=$(aws configservice describe-configuration-recorders \
        --region $REGION \
        --query 'ConfigurationRecorders[0].recordingGroup.resourceTypes' \
        --output json 2>/dev/null)
    
    # Verify it's recording our required types
    if [ "$RECORDING_STRATEGY" = "INCLUSION_BY_RESOURCE_TYPES" ]; then
        if echo "$RESOURCE_TYPES" | grep -q "AWS::ApiGateway::RestApi" && \
           echo "$RESOURCE_TYPES" | grep -q "AWS::ApiGatewayV2::Api" && \
           echo "$RESOURCE_TYPES" | grep -q "AWS::ElasticLoadBalancingV2::LoadBalancer"; then
            print_info "✅ Config is properly configured in $REGION"
            return 0
        fi
    fi
    
    # If we get here, recording settings may be wrong
    print_warning "Config recording settings may need adjustment in $REGION"
    print_warning "Required types: AWS::ApiGateway::RestApi, AWS::ApiGatewayV2::Api, AWS::ElasticLoadBalancingV2::LoadBalancer"
    
    # Ask if user wants to continue anyway
    read -p "Continue anyway? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        return 1
    fi
    
    return 0
}

# Wait for conformance pack to complete
wait_for_conformance_pack() {
    local REGION=$1
    local ELAPSED=0
    
    print_info "Waiting for conformance pack creation in $REGION..."
    
    while [ $ELAPSED -lt $MAX_WAIT_SECONDS ]; do
        STATUS=$(aws configservice describe-conformance-pack-status \
            --conformance-pack-names $CONFORMANCE_PACK_NAME \
            --region $REGION \
            --query 'ConformancePackStatusDetails[0].ConformancePackState' \
            --output text 2>/dev/null || echo "UNKNOWN")
        
        if [ "$STATUS" = "CREATE_COMPLETE" ]; then
            print_info "✅ Conformance pack created successfully in $REGION"
            return 0
        elif [[ "$STATUS" == *"FAILED"* ]]; then
            print_error "❌ Conformance pack creation failed in $REGION: $STATUS"
            return 1
        elif [ "$STATUS" = "UNKNOWN" ]; then
            print_error "❌ Could not query conformance pack status in $REGION"
            return 1
        fi
        
        printf "\r⏳ Status: $STATUS [${ELAPSED}s/${MAX_WAIT_SECONDS}s]"
        sleep 10
        ELAPSED=$((ELAPSED + 10))
    done
    
    echo ""
    print_error "❌ Timed out waiting for conformance pack in $REGION"
    return 1
}

# Verify Config rules were created
verify_config_rules() {
    local REGION=$1
    print_info "Verifying Config rules in $REGION..."
    
    RULE_COUNT=$(aws configservice describe-config-rules \
        --region $REGION \
        --query 'length(ConfigRules[?contains(ConfigRuleName, `pqc`)])' \
        --output text)
    
    if [ "$RULE_COUNT" = "4" ]; then
        print_info "✅ All 4 Config rules created in $REGION"
        return 0
    else
        print_warning "⚠️  Expected 4 rules, found $RULE_COUNT in $REGION"
        return 1
    fi
}

# Deploy to a single region
deploy_to_region() {
    local REGION=$1
    
    print_section "Deploying to $REGION"
    
    # Step 0: Check prerequisites
    if ! check_config_prerequisites $REGION; then
        print_error "Prerequisites not met for $REGION"
        return 1
    fi
    
    # Step 1: Deploy SAM stack
    print_info "Step 1: Deploying SAM stack to $REGION..."
    
    if ! sam deploy \
        --stack-name $STACK_NAME \
        --region $REGION \
        --capabilities CAPABILITY_IAM \
        --resolve-s3 \
        --no-confirm-changeset \
        --no-fail-on-empty-changeset; then
        print_error "SAM deployment failed in $REGION"
        return 1
    fi
    
    print_info "✅ SAM stack deployed successfully in $REGION"
    
    # Step 2: Deploy conformance pack
    print_info "Step 2: Deploying conformance pack to $REGION..."
    
    if ! aws configservice put-conformance-pack \
        --conformance-pack-name $CONFORMANCE_PACK_NAME \
        --region $REGION \
        --template-body file://../conformance-packs/pqc-legacy-tls-conformance-pack.yaml \
        > /dev/null; then
        print_error "Conformance pack deployment failed in $REGION"
        return 1
    fi
    
    # Step 3: Wait for conformance pack completion
    if ! wait_for_conformance_pack $REGION; then
        return 1
    fi
    
    # Step 4: Verify Config rules
    if ! verify_config_rules $REGION; then
        print_warning "Config rules verification had issues in $REGION"
    fi
    
    print_info "✅ Deployment to $REGION complete!\n"
    return 0
}

# Main script
main() {
    # Parse arguments
    REGIONS=("$@")
    
    # Validate inputs
    if [ ${#REGIONS[@]} -eq 0 ]; then
        echo "Usage: $0 <region1> [region2] [region3] ..."
        echo ""
        echo "Examples:"
        echo "  $0 us-east-1"
        echo "  $0 us-east-1 us-west-2"
        echo "  $0 us-east-1 us-west-2 eu-west-1"
        exit 1
    fi
    
    # Get account ID
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    
    print_section "PQC Scanner Multi-Region Deployment"
    echo "Account:   $ACCOUNT_ID"
    echo "Regions:   ${REGIONS[*]}"
    echo ""
    
    # Build SAM once (used by all regions)
    print_info "Building SAM application..."
    if ! sam build; then
        print_error "SAM build failed"
        exit 1
    fi
    print_info "✅ SAM build complete\n"
    
    # Deploy to regions sequentially
    FAILED_REGIONS=()
    SUCCESS_REGIONS=()
    
    for REGION in "${REGIONS[@]}"; do
        if deploy_to_region $REGION; then
            SUCCESS_REGIONS+=("$REGION")
        else
            FAILED_REGIONS+=("$REGION")
        fi
    done
    
    # Print summary
    print_section "Deployment Summary"
    
    if [ ${#SUCCESS_REGIONS[@]} -gt 0 ]; then
        echo -e "${GREEN}✅ Successful Deployments (${#SUCCESS_REGIONS[@]}):${NC}"
        for REGION in "${SUCCESS_REGIONS[@]}"; do
            echo "   - $REGION"
        done
        echo ""
    fi
    
    if [ ${#FAILED_REGIONS[@]} -gt 0 ]; then
        echo -e "${RED}❌ Failed Deployments (${#FAILED_REGIONS[@]}):${NC}"
        for REGION in "${FAILED_REGIONS[@]}"; do
            echo "   - $REGION"
        done
        echo ""
        exit 1
    fi
    
    print_info "All deployments completed successfully!"
    echo ""
    echo "Next steps:"
    echo "1. Check AWS Config console in each region for compliance results"
    echo "2. Trigger evaluation if needed:"
    echo "   aws configservice start-config-rules-evaluation --config-rule-names <rule-names> --region <region>"
    echo ""
}

# Run main
main "$@"