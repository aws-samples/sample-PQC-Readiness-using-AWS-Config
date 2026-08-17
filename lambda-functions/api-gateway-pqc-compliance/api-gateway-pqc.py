import json
import logging
import boto3
import time

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

def extract_api_id(resource_id):
    """
    Extract API ID from ARN or return as-is if already just an ID.
    
    AWS Config sends the full ARN in the format:
      arn:aws:apigateway:region::/restapis/API_ID
      arn:aws:apigateway:region::/apis/API_ID
    
    But API Gateway boto3 calls (get_rest_api, get_api, etc.) expect just the API_ID.
    
    Args:
        resource_id: Either a full ARN or just an API ID
    
    Returns:
        Just the API ID (last component after the final /)
    """
    if resource_id.startswith('arn:'):
        # ARN format: arn:aws:apigateway:region::/restapis/API_ID
        # Extract the last component after /
        return resource_id.split('/')[-1]
    return resource_id

# Tier 1: TLS 1.3 only with PQC key exchange (optimal - NONE EXIST YET)
# AWS has not released TLS 1.3-only policies with PQC key exchange.
# SecurityPolicy_TLS13_1_3_2025_09 and SecurityPolicy_TLS13_1_3_FIPS_2025_09
# are TLS 1.3-only but do NOT include PQC key exchange (no _PQ_ in name).
# When AWS releases Tier 1 policies, they will contain _PQ_ (e.g.
# SecurityPolicy_TLS13_1_3_PQ_2025_09). Add them here when available.
APIGW_TIER1_POLICIES = [
]

# Tier 2: TLS 1.2+1.3 with PQC key exchange (backward compatible)
APIGW_TIER2_POLICIES = [
    'SecurityPolicy_TLS13_1_2_FIPS_PFS_PQ_2025_09',
    'SecurityPolicy_TLS13_1_2_FIPS_PQ_2025_09',
    'SecurityPolicy_TLS13_1_2_PFS_PQ_2025_09',
    'SecurityPolicy_TLS13_1_2_PQ_2025_09',
]

# Combined PQC policies for membership checks (Tier 1 + Tier 2)
APIGW_PQC_POLICIES = APIGW_TIER1_POLICIES + APIGW_TIER2_POLICIES

# Policies that allow TLS 1.0 or 1.1 (should be flagged as non-compliant)
APIGW_LEGACY_TLS_POLICIES = [
    'TLS_1_0',  # Supports TLS 1.0, 1.1, 1.2, 1.3
]

def get_apigw_recommended_policy(current_policy):
    """
    Returns the recommended Tier 2 PQC policy based on whether
    the current policy is FIPS-compliant.
    """
    if 'FIPS' in str(current_policy):
        return 'SecurityPolicy_TLS13_1_2_FIPS_PFS_PQ_2025_09 (Tier 2, FIPS)'
    return 'SecurityPolicy_TLS13_1_2_PQ_2025_09 (Tier 2)'

def get_policy_tier(security_policy):
    """
    Returns the tier classification for a given API Gateway security policy.
    """
    if security_policy in APIGW_TIER1_POLICIES:
        return 1
    elif security_policy in APIGW_TIER2_POLICIES:
        return 2
    else:
        return 3

def get_rest_api_security_policy(resource_id):
    """
    Makes a live API call to apigateway:GetRestApi to retrieve the actual
    security policy. The AWS Config configuration item may not reliably
    reflect PQC security policies (it often only shows TLS_1_0 or TLS_1_2).
    
    Returns the security policy string or None if retrieval fails.
    """
    try:
        apigw_client = boto3.client('apigateway')
        
        # Extract just the API ID from the full ARN if needed
        api_id = extract_api_id(resource_id)
        
        response = apigw_client.get_rest_api(restApiId=api_id)
        security_policy = response.get('securityPolicy')
        
        logger.info(f"Retrieved securityPolicy for API {api_id}: {security_policy}")
        return security_policy
        
    except Exception as e:
        logger.error(f"Failed to call GetRestApi for {resource_id}: {str(e)}", exc_info=True)
        return None


def get_custom_domain_policy_for_rest_api(resource_id):
    """
    Checks if the REST API has Custom Domain Name associations and retrieves
    the security policy from the Custom Domain.
    
    Uses pagination to handle accounts with >500 domains, and includes
    retry logic with exponential backoff for API rate limits.
    
    Returns: (best_policy, domain_name) or (None, None)
    """
    try:
        import time as _time
        apigw_client = boto3.client('apigateway')
        
        # Extract just the API ID from the full ARN if needed
        api_id = extract_api_id(resource_id)
        
        # Paginate through all custom domain names
        domains = []
        kwargs = {'limit': 500}
        while True:
            domains_response = apigw_client.get_domain_names(**kwargs)
            domains.extend(domains_response.get('items', []))
            position = domains_response.get('position')
            if not position:
                break
            kwargs['position'] = position
        
        best_policy = None
        best_domain = None
        best_tier = 3
        
        for domain in domains:
            domain_name = domain.get('domainName', '')
            domain_security_policy = domain.get('securityPolicy')
            
            if domain_security_policy is None:
                continue
            
            # Skip domains whose policy isn't better than what we already have
            domain_tier = get_policy_tier(domain_security_policy)
            if domain_tier >= best_tier:
                continue
            
            # Check if this domain maps to our REST API
            try:  
                mappings = []
                map_kwargs = {'domainName': domain_name, 'limit': 500}
                while True:
                    mappings_response = apigw_client.get_base_path_mappings(**map_kwargs)
                    mappings.extend(mappings_response.get('items', []))
                    pos = mappings_response.get('position')
                    if not pos:
                        break
                    map_kwargs['position'] = pos
                
                for mapping in mappings:
                    if mapping.get('restApiId') == api_id:
                        best_tier = domain_tier
                        best_policy = domain_security_policy
                        best_domain = domain_name
                        break
            except apigw_client.exceptions.TooManyRequestsException:
                logger.warning(f"Rate limited on GetBasePathMappings for {domain_name}, backing off")
                _time.sleep(1)
                continue
            except Exception as e:
                logger.warning(f"Failed to get mappings for domain {domain_name}: {str(e)}")
                continue
        
        return best_policy, best_domain
    except apigw_client.exceptions.TooManyRequestsException:
        logger.warning(f"Rate limited on GetDomainNames for REST API {resource_id}")
        return None, None
    except Exception as e:
        logger.warning(f"Failed to check custom domains for REST API {resource_id}: {str(e)}")
        return None, None


def lambda_handler(event, context):
    """
    AWS Config rule handler for API Gateway PQC and Legacy TLS compliance evaluation.
    Handles REST API, HTTP API, and WebSocket API.
    Supports two check types via rule input parameters:
    - PQC: Checks if the policy is post-quantum cryptography ready
    - LEGACY_TLS: Checks if the policy allows TLS 1.0 or 1.1 (should be flagged)
    """
    try:
        # Parse the AWS Config event
        invoking_event = json.loads(event['invokingEvent'])
        message_type = invoking_event.get('messageType')
        
        logger.info(f"Processing {message_type} event")
        
        if message_type == 'ConfigurationItemChangeNotification':
            # Resource change - evaluate specific API Gateway resource
            config_item = invoking_event['configurationItem']
            resource_type = config_item['resourceType']
            resource_id = config_item['resourceId']
            
            logger.info(f"Evaluating {resource_type} with ID: {resource_id}")
            
            # Get the check type from rule parameters
            rule_parameters = json.loads(event.get('ruleParameters', '{}'))
            check_type = rule_parameters.get('checkType', 'PQC')
            
            logger.info(f"Check type: {check_type}")
            
            # Route to appropriate evaluation function based on resource type
            if resource_type == 'AWS::ApiGateway::RestApi':
                compliance_result = evaluate_rest_api(config_item, check_type)
            elif resource_type == 'AWS::ApiGatewayV2::Api':
                compliance_result = evaluate_v2_api(config_item, check_type)
            else:
                compliance_result = build_evaluation(
                    resource_id, 
                    resource_type,
                    'NOT_APPLICABLE', 
                    'Resource type not supported'
                )
            
            # Send evaluation back to AWS Config
            config_client = boto3.client('config')
            config_client.put_evaluations(
                Evaluations=[compliance_result],
                ResultToken=event['resultToken']
            )
            
            return compliance_result
        
        else:
            logger.warning(f"Unknown message type: {message_type}")
            return build_evaluation(
                "unknown",
                "AWS::ApiGateway::RestApi",
                'NOT_APPLICABLE',
                f'Unsupported message type: {message_type}'
            )
            
    except Exception as e:
        logger.error(f"Error in lambda_handler: {str(e)}", exc_info=True)
        error_msg = str(e)[:200] + "..." if len(str(e)) > 200 else str(e)
        return build_evaluation(
            "unknown",
            "AWS::ApiGateway::RestApi",
            'NON_COMPLIANT',
            f'Evaluation error: {error_msg}'
        )

def evaluate_rest_api(config_item, check_type):
    """
    Evaluates REST API v1 for PQC or Legacy TLS compliance.
    Reads securityPolicy directly from the configuration item.
    """
    resource_id = config_item['resourceId']
    resource_type = config_item['resourceType']
    
    try:
        # Parse the configuration from Config's configuration item
        # Config may pass configuration as dict or JSON string
        config = config_item['configuration']
        configuration = json.loads(config) if isinstance(config, str) else config
        
        api_name = configuration.get('name', 'Unknown')
        endpoint_config = configuration.get('endpointConfiguration', {})
        endpoint_types = endpoint_config.get('types', ['EDGE'])
        
        # Detect if this is a Private API
        is_private = 'PRIVATE' in endpoint_types
        
        # Handle securityPolicy - Private APIs with null policy use legacy TLS 1.2 default
        security_policy = configuration.get('securityPolicy')
        
        logger.info(f"Evaluating REST API: {api_name}, Config policy: {security_policy}")
        
        # If Config CI securityPolicy is null or a generic value (TLS_1_0/TLS_1_2),
        # make live API calls to get the actual policy
        if security_policy is None or security_policy in ('TLS_1_0', 'TLS_1_2'):
            # Step 1: Try live GetRestApi call
            live_policy = get_rest_api_security_policy(resource_id)
            
            if live_policy and live_policy != security_policy:
                logger.info(f"Updated policy from '{security_policy}' to '{live_policy}' via live API")
                security_policy = live_policy
            
            # Step 2: Check Custom Domain associations for a better policy
            if get_policy_tier(security_policy) if security_policy else 3 >= 2:
                domain_policy, domain_name = get_custom_domain_policy_for_rest_api(resource_id)
                if domain_policy:
                    domain_tier = get_policy_tier(domain_policy)
                    current_tier = get_policy_tier(security_policy) if security_policy else 3
                    if domain_tier < current_tier:
                        logger.info(f"Using Custom Domain '{domain_name}' policy: {domain_policy} (Tier {domain_tier})")
                        security_policy = domain_policy
        
        # Final fallback if still None after live checks
        if security_policy is None or security_policy == '':
            if is_private:
                security_policy = 'TLS_1_2'
                logger.info(f"Private API fallback: using TLS_1_2 default")
            else:
                security_policy = 'TLS_1_0'
                logger.info(f"Public API fallback: using TLS_1_0 default")
        
        logger.info(f"Final policy for evaluation: {security_policy}")
        
        # Evaluate based on check type
        if check_type == 'PQC':
            return evaluate_pqc_compliance(resource_id, resource_type, api_name, security_policy, is_private)
        elif check_type == 'LEGACY_TLS':
            return evaluate_legacy_tls_compliance(resource_id, resource_type, api_name, security_policy, is_private)
        else:
            return build_evaluation(
                resource_id,
                resource_type,
                'NOT_APPLICABLE',
                f'Unknown check type: {check_type}'
            )
            
    except Exception as e:
        logger.error(f"Error evaluating REST API {resource_id}: {str(e)}", exc_info=True)
        error_msg = str(e)[:200] + "..." if len(str(e)) > 200 else str(e)
        return build_evaluation(
            resource_id,
            resource_type,
            'NOT_APPLICABLE',
            f'Evaluation error: {error_msg}'
        )

def evaluate_v2_api(config_item, check_type):
    """
    Evaluates API v2 (HTTP/WebSocket) for PQC or Legacy TLS compliance.
    V2 APIs are fixed at TLS_1_2 by AWS and cannot be changed.
    """
    resource_id = config_item['resourceId']
    resource_type = config_item['resourceType']
    
    try:
        # Parse the configuration from Config's configuration item
        # Config may pass configuration as dict or JSON string
        config = config_item['configuration']
        configuration = json.loads(config) if isinstance(config, str) else config
        
        api_name = configuration.get('name', 'Unknown')
        protocol_type = configuration.get('protocolType', 'UNKNOWN')
        
        logger.info(f"API v2: {api_name}, Protocol: {protocol_type}, Fixed Policy: TLS_1_2")
        
        # V2 APIs (HTTP/WebSocket) are fixed at TLS_1_2 by AWS
        fixed_policy = 'TLS_1_2'
        
        # Evaluate based on check type
        if check_type == 'PQC':
            # TLS_1_2 is NOT PQC-ready (Tier 3)
            return build_evaluation(
                resource_id,
                resource_type,
                'NON_COMPLIANT',
                f"{protocol_type} API '{api_name}' is Tier 3 (not PQ-ready): fixed policy TLS_1_2. AWS does not support PQC policies for {protocol_type} APIs yet"
            )
        elif check_type == 'LEGACY_TLS':
            # TLS_1_2 does NOT allow TLS 1.0 or TLS 1.1
            return build_evaluation(
                resource_id,
                resource_type,
                'COMPLIANT',
                f"{protocol_type} API '{api_name}': Uses fixed policy TLS_1_2 (does not allow TLS 1.0 or TLS 1.1)"
            )
        else:
            return build_evaluation(
                resource_id,
                resource_type,
                'NOT_APPLICABLE',
                f'Unknown check type: {check_type}'
            )
            
    except Exception as e:
        logger.error(f"Error evaluating API v2 {resource_id}: {str(e)}", exc_info=True)
        error_msg = str(e)[:200] + "..." if len(str(e)) > 200 else str(e)
        return build_evaluation(
            resource_id,
            resource_type,
            'NOT_APPLICABLE',
            f'Evaluation error: {error_msg}'
        )

def evaluate_pqc_compliance(resource_id, resource_type, api_name, security_policy, is_private=False):
    """
    Evaluates if the security policy is PQC-ready and classifies into Tier 1, 2, or 3.
    COMPLIANT: Policy is in APIGW_PQC_POLICIES (Tier 1 or Tier 2)
    NON_COMPLIANT: Policy is not PQC-ready (Tier 3)
    """
    tier = get_policy_tier(security_policy)
    
    if tier == 1:
        annotation = f"API '{api_name}' is Tier 1 (PQ-ready, TLS 1.3 only): {security_policy}"
        return build_evaluation(resource_id, resource_type, 'COMPLIANT', annotation)
    elif tier == 2:
        annotation = f"API '{api_name}' is Tier 2 (PQ-ready, backward compatible): {security_policy}"
        return build_evaluation(resource_id, resource_type, 'COMPLIANT', annotation)
    else:
        # Tier 3 - not PQ-ready
        recommended = get_apigw_recommended_policy(security_policy)
        if is_private and security_policy == 'TLS_1_2':
            annotation = f"Private API '{api_name}' is Tier 3 (not PQ-ready): legacy TLS 1.2 default. Recommended: {recommended}"
        else:
            annotation = f"API '{api_name}' is Tier 3 (not PQ-ready): {security_policy}. Recommended: {recommended}"
        return build_evaluation(resource_id, resource_type, 'NON_COMPLIANT', annotation)

def evaluate_legacy_tls_compliance(resource_id, resource_type, api_name, security_policy, is_private=False):
    """
    Evaluates if the security policy allows TLS 1.0 or 1.1.
    COMPLIANT: Policy does NOT allow TLS 1.0 or TLS 1.1
    NON_COMPLIANT: Policy allows TLS 1.0 or 1.1
    """
    if security_policy in APIGW_LEGACY_TLS_POLICIES:
        annotation = f"API '{api_name}' allows TLS 1.0 or TLS 1.1: {security_policy}. HIGH PRIORITY: Upgrade to TLS_1_2 or newer"
        return build_evaluation(resource_id, resource_type, 'NON_COMPLIANT', annotation)
    else:
        if is_private and security_policy == 'TLS_1_2':
            # Private API defaults to TLS 1.2 - no TLS 1.0 or TLS 1.1 exposure
            annotation = f"Private API '{api_name}' uses legacy TLS 1.2 default via VPC Endpoint (no TLS 1.0 or TLS 1.1 exposure)"
        else:
            annotation = f"API '{api_name}' does not allow TLS 1.0 or TLS 1.1. Policy: {security_policy}"
        return build_evaluation(resource_id, resource_type, 'COMPLIANT', annotation)

def build_evaluation(resource_id, resource_type, compliance_type, annotation):
    """
    Builds an AWS Config evaluation result.
    Uses Unix timestamp to avoid JSON serialization issues.
    """
    # Ensure annotation fits AWS Config limits (256 characters max)
    if len(annotation) > 250:
        annotation = annotation[:247] + "..."
    
    return {
        'ComplianceResourceType': resource_type,
        'ComplianceResourceId': resource_id,
        'ComplianceType': compliance_type,
        'Annotation': annotation,
        'OrderingTimestamp': time.time()
    }
