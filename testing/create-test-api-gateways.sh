#!/bin/bash

# API Gateway PQC Compliance Testing - Create Test APIs
# This script creates one of each API Gateway type for testing PQC compliance

# Remove set -e to allow script to continue on errors
# set -e

echo "Creating test API Gateway resources for PQC compliance testing..."

# Initialize variables for tracking success
REST_API_ID=""
HTTP_API_ID=""
WEBSOCKET_API_ID=""
PRIVATE_API_ID=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if AWS CLI is configured
if ! aws sts get-caller-identity > /dev/null 2>&1; then
    print_error "AWS CLI not configured. Please run 'aws configure' first."
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region || echo "us-east-1")

print_status "Using AWS Account: $ACCOUNT_ID"
print_status "Using Region: $REGION"

# =============================================================================
# 1. REST API v1 (Regular)
# =============================================================================
print_status "Creating REST API v1..."

REST_API_ID=$(aws apigateway create-rest-api \
    --name "pqc-test-rest-api" \
    --description "PQC Test - REST API v1" \
    --endpoint-configuration types=REGIONAL \
    --query 'id' --output text)

print_status "Created REST API v1: $REST_API_ID"

# Get the root resource ID
ROOT_RESOURCE_ID=$(aws apigateway get-resources \
    --rest-api-id $REST_API_ID \
    --query 'items[0].id' --output text)

# Create a simple resource and method
RESOURCE_ID=$(aws apigateway create-resource \
    --rest-api-id $REST_API_ID \
    --parent-id $ROOT_RESOURCE_ID \
    --path-part "test" \
    --query 'id' --output text)

aws apigateway put-method \
    --rest-api-id $REST_API_ID \
    --resource-id $RESOURCE_ID \
    --http-method GET \
    --authorization-type NONE > /dev/null

aws apigateway put-integration \
    --rest-api-id $REST_API_ID \
    --resource-id $RESOURCE_ID \
    --http-method GET \
    --type MOCK \
    --request-templates '{"application/json": "{\"statusCode\": 200}"}' > /dev/null

aws apigateway put-method-response \
    --rest-api-id $REST_API_ID \
    --resource-id $RESOURCE_ID \
    --http-method GET \
    --status-code 200 > /dev/null

aws apigateway put-integration-response \
    --rest-api-id $REST_API_ID \
    --resource-id $RESOURCE_ID \
    --http-method GET \
    --status-code 200 \
    --response-templates '{"application/json": "{\"message\": \"Hello from REST API v1\"}"}' > /dev/null

# Deploy the API
aws apigateway create-deployment \
    --rest-api-id $REST_API_ID \
    --stage-name test > /dev/null

print_status "REST API v1 deployed: https://$REST_API_ID.execute-api.$REGION.amazonaws.com/test"

# =============================================================================
# 2. HTTP API v2
# =============================================================================
print_status "Creating HTTP API v2..."

HTTP_API_ID=$(aws apigatewayv2 create-api \
    --name "pqc-test-http-api" \
    --protocol-type HTTP \
    --description "PQC Test - HTTP API v2" \
    --query 'ApiId' --output text)

print_status "Created HTTP API v2: $HTTP_API_ID"

# Create a mock integration FIRST
INTEGRATION_ID=$(aws apigatewayv2 create-integration \
    --api-id $HTTP_API_ID \
    --integration-type MOCK \
    --payload-format-version "1.0" \
    --integration-response-selection-expression "200" \
    --query 'IntegrationId' --output text)

print_status "Created integration: $INTEGRATION_ID"

# Create integration response
aws apigatewayv2 create-integration-response \
    --api-id $HTTP_API_ID \
    --integration-id $INTEGRATION_ID \
    --integration-response-key "200" \
    --response-templates '{"application/json": "{\"message\": \"Hello from HTTP API v2\"}"}' > /dev/null

# Create route with correct integration target
ROUTE_ID=$(aws apigatewayv2 create-route \
    --api-id $HTTP_API_ID \
    --route-key "GET /test" \
    --target "integrations/$INTEGRATION_ID" \
    --query 'RouteId' --output text)

# Create route response
aws apigatewayv2 create-route-response \
    --api-id $HTTP_API_ID \
    --route-id $ROUTE_ID \
    --route-response-key "200" > /dev/null

# Create and deploy stage
aws apigatewayv2 create-stage \
    --api-id $HTTP_API_ID \
    --stage-name test \
    --auto-deploy > /dev/null

print_status "HTTP API v2 deployed: https://$HTTP_API_ID.execute-api.$REGION.amazonaws.com/test"

# =============================================================================
# 3. WebSocket API v2
# =============================================================================
print_status "Creating WebSocket API v2..."

WEBSOCKET_API_ID=$(aws apigatewayv2 create-api \
    --name "pqc-test-websocket-api" \
    --protocol-type WEBSOCKET \
    --route-selection-expression "\$request.body.action" \
    --description "PQC Test - WebSocket API v2" \
    --query 'ApiId' --output text)

print_status "Created WebSocket API v2: $WEBSOCKET_API_ID"

# Create routes for WebSocket
aws apigatewayv2 create-route \
    --api-id $WEBSOCKET_API_ID \
    --route-key "\$connect" > /dev/null

aws apigatewayv2 create-route \
    --api-id $WEBSOCKET_API_ID \
    --route-key "\$disconnect" > /dev/null

aws apigatewayv2 create-route \
    --api-id $WEBSOCKET_API_ID \
    --route-key "\$default" > /dev/null

# Create and deploy stage
aws apigatewayv2 create-stage \
    --api-id $WEBSOCKET_API_ID \
    --stage-name test \
    --auto-deploy > /dev/null

print_status "WebSocket API v2 deployed: wss://$WEBSOCKET_API_ID.execute-api.$REGION.amazonaws.com/test"

# =============================================================================
# 4. REST API v1 (Private)
# =============================================================================
print_status "Creating Private REST API v1..."

PRIVATE_API_ID=$(aws apigateway create-rest-api \
    --name "pqc-test-private-rest-api" \
    --description "PQC Test - Private REST API v1" \
    --endpoint-configuration types=PRIVATE \
    --policy '{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": "*",
                "Action": "execute-api:Invoke",
                "Resource": "*"
            }
        ]
    }' \
    --query 'id' --output text)

print_status "Created Private REST API v1: $PRIVATE_API_ID"

# Get the root resource ID
PRIVATE_ROOT_RESOURCE_ID=$(aws apigateway get-resources \
    --rest-api-id $PRIVATE_API_ID \
    --query 'items[0].id' --output text)

# Create a simple resource and method
PRIVATE_RESOURCE_ID=$(aws apigateway create-resource \
    --rest-api-id $PRIVATE_API_ID \
    --parent-id $PRIVATE_ROOT_RESOURCE_ID \
    --path-part "test" \
    --query 'id' --output text)

aws apigateway put-method \
    --rest-api-id $PRIVATE_API_ID \
    --resource-id $PRIVATE_RESOURCE_ID \
    --http-method GET \
    --authorization-type NONE > /dev/null

aws apigateway put-integration \
    --rest-api-id $PRIVATE_API_ID \
    --resource-id $PRIVATE_RESOURCE_ID \
    --http-method GET \
    --type MOCK \
    --request-templates '{"application/json": "{\"statusCode\": 200}"}' > /dev/null

aws apigateway put-method-response \
    --rest-api-id $PRIVATE_API_ID \
    --resource-id $PRIVATE_RESOURCE_ID \
    --http-method GET \
    --status-code 200 > /dev/null

aws apigateway put-integration-response \
    --rest-api-id $PRIVATE_API_ID \
    --resource-id $PRIVATE_RESOURCE_ID \
    --http-method GET \
    --status-code 200 \
    --response-templates '{"application/json": "{\"message\": \"Hello from Private REST API v1\"}"}' > /dev/null

# Deploy the API
aws apigateway create-deployment \
    --rest-api-id $PRIVATE_API_ID \
    --stage-name test > /dev/null

print_status "Private REST API v1 deployed (requires VPC endpoint access)"

# =============================================================================
# Summary
# =============================================================================
echo ""
print_status "=== API Gateway Test Resources Created ==="
echo "1. REST API v1:      $REST_API_ID"
echo "2. HTTP API v2:      $HTTP_API_ID"
echo "3. WebSocket API v2: $WEBSOCKET_API_ID"
echo "4. Private REST API: $PRIVATE_API_ID"
echo ""

print_status "=== Test URLs ==="
echo "1. REST API v1:      https://$REST_API_ID.execute-api.$REGION.amazonaws.com/test/test"
echo "2. HTTP API v2:      https://$HTTP_API_ID.execute-api.$REGION.amazonaws.com/test"
echo "3. WebSocket API v2: wss://$WEBSOCKET_API_ID.execute-api.$REGION.amazonaws.com/test"
echo "4. Private REST API: Requires VPC endpoint"
echo ""

print_warning "Note: These APIs use default AWS certificates (PQC compliant)"
print_warning "To test non-compliance, create custom domain names with TLS_1_0 policy"

# =============================================================================
# Create Custom Domain Examples (Commented out - requires real certificate)
# =============================================================================
cat << 'EOF'

# OPTIONAL: Create custom domains for compliance testing
# (Requires real ACM certificate - uncomment and modify as needed)

# Non-compliant domain (TLS_1_0)
# aws apigateway create-domain-name \
#     --domain-name "api-test-non-compliant.yourdomain.com" \
#     --certificate-arn "arn:aws:acm:us-east-1:123456789012:certificate/your-cert-id" \
#     --security-policy TLS_1_0

# Compliant domain (TLS_1_2)
# aws apigateway create-domain-name \
#     --domain-name "api-test-compliant.yourdomain.com" \
#     --certificate-arn "arn:aws:acm:us-east-1:123456789012:certificate/your-cert-id" \
#     --security-policy TLS_1_2

# Create base path mapping
# aws apigateway create-base-path-mapping \
#     --domain-name "api-test-compliant.yourdomain.com" \
#     --rest-api-id $REST_API_ID \
#     --stage test

EOF

print_status "API Gateway test resources created successfully!"
print_status "Run your PQC compliance Lambda function to test evaluation."

# Save API IDs to file for cleanup
cat > api-gateway-test-resources.txt << EOF
# API Gateway Test Resources
# Created: $(date)
REST_API_ID=$REST_API_ID
HTTP_API_ID=$HTTP_API_ID
WEBSOCKET_API_ID=$WEBSOCKET_API_ID
PRIVATE_API_ID=$PRIVATE_API_ID
REGION=$REGION
EOF

print_status "Resource IDs saved to: api-gateway-test-resources.txt"
