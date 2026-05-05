import boto3
import json
import logging
import time
from botocore.exceptions import ClientError

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Tier 1: TLS 1.3 only with PQC key exchange (optimal)
ELB_TIER1_POLICIES = [
    'ELBSecurityPolicy-TLS13-1-3-PQ-2025-09',
    'ELBSecurityPolicy-TLS13-1-3-FIPS-PQ-2025-09',
]

# Tier 2: TLS 1.2+1.3 with PQC key exchange (backward compatible)
# NOTE: TLS13-1-0-PQ policies are PQC-ready but also allow TLS 1.0 - flagged separately by Legacy TLS rule
ELB_TIER2_POLICIES = [
    'ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09',
    'ELBSecurityPolicy-TLS13-1-2-Res-FIPS-PQ-2025-09',
    'ELBSecurityPolicy-TLS13-1-2-PQ-2025-09',
    'ELBSecurityPolicy-TLS13-1-2-FIPS-PQ-2025-09',
    'ELBSecurityPolicy-TLS13-1-2-Ext1-PQ-2025-09',
    'ELBSecurityPolicy-TLS13-1-2-Ext2-PQ-2025-09',
    'ELBSecurityPolicy-TLS13-1-0-PQ-2025-09',
    'ELBSecurityPolicy-TLS13-1-0-FIPS-PQ-2025-09',
]

# Combined PQC policies for membership checks (Tier 1 + Tier 2)
ELB_PQC_POLICIES = ELB_TIER1_POLICIES + ELB_TIER2_POLICIES

# Policies that allow TLS 1.0 or 1.1 (should be flagged as non-compliant)
ELB_LEGACY_TLS_POLICIES = [
    # TLS 1.0 + 1.1 support (newer policies)
    'ELBSecurityPolicy-TLS13-1-0-2021-06',
    'ELBSecurityPolicy-TLS13-1-0-PQ-2025-09',
    'ELBSecurityPolicy-TLS13-1-0-FIPS-2023-04',
    'ELBSecurityPolicy-TLS13-1-0-FIPS-PQ-2025-09',
    'ELBSecurityPolicy-2016-08',
    # TLS 1.0 + 1.1 support (older 2015 policies)
    'ELBSecurityPolicy-TLS-1-0-2015-04',
    'ELBSecurityPolicy-2015-05',
    'ELBSecurityPolicy-TLS-1-0-2015-05',
    # TLS 1.1 support (no TLS 1.0)
    'ELBSecurityPolicy-TLS13-1-1-2021-06',
    'ELBSecurityPolicy-TLS13-1-1-FIPS-2023-04',
    'ELBSecurityPolicy-TLS-1-1-2017-01',
]

def get_elb_recommended_policy(current_policy):
    """
    Returns the recommended Tier 2 PQC policy based on whether
    the current policy is FIPS-compliant.
    """
    if 'FIPS' in current_policy:
        return 'ELBSecurityPolicy-TLS13-1-2-Res-FIPS-PQ-2025-09 (Tier 2, FIPS)'
    return 'ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09 (Tier 2)'

def get_policy_tier(ssl_policy):
    """
    Returns the tier classification for a given ELB security policy.
    """
    if ssl_policy in ELB_TIER1_POLICIES:
        return 1
    elif ssl_policy in ELB_TIER2_POLICIES:
        return 2
    else:
        return 3

def lambda_handler(event, context):
    """
    AWS Config rule handler for ELB PQC and Legacy TLS compliance evaluation.
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
            # Resource change - evaluate specific load balancer
            config_item = invoking_event['configurationItem']
            resource_type = config_item['resourceType']
            resource_id = config_item['resourceId']
            
            # Only evaluate ELB resources
            if resource_type not in ['AWS::ElasticLoadBalancingV2::LoadBalancer']:
                return build_evaluation(resource_id, 'NOT_APPLICABLE', 'Resource type not supported')
            
            # Get the check type from rule parameters
            rule_parameters = json.loads(event.get('ruleParameters', '{}'))
            check_type = rule_parameters.get('checkType', 'PQC')
            
            logger.info(f"Check type: {check_type} for resource: {resource_id}")
            
            # Evaluate load balancer (uses API calls to get listener details)
            compliance_result = evaluate_elb_compliance(resource_id, check_type)
            
            # Send evaluation back to AWS Config
            config_client = boto3.client('config')
            config_client.put_evaluations(
                Evaluations=[compliance_result],
                ResultToken=event['resultToken']
            )
            
            return compliance_result
        
        else:
            logger.warning(f"Unknown message type: {message_type}")
            return build_evaluation("unknown", 'NOT_APPLICABLE', f'Unsupported message type: {message_type}')
            
    except Exception as e:
        logger.error(f"Error in lambda_handler: {str(e)}", exc_info=True)
        error_msg = str(e)[:200] + "..." if len(str(e)) > 200 else str(e)
        return build_evaluation("unknown", 'NON_COMPLIANT', f'Evaluation error: {error_msg}')

def evaluate_elb_compliance(load_balancer_arn, check_type):
    """
    Evaluates a single load balancer for PQC or Legacy TLS compliance.
    Returns AWS Config evaluation result.
    
    Note: AWS Config does not include listener SSL policies in the configurationItem,
    so we must use API calls to get listener details.
    """
    try:
        client = boto3.client('elbv2')
        
        # Get load balancer details
        try:
            lb_response = client.describe_load_balancers(LoadBalancerArns=[load_balancer_arn])
            if not lb_response['LoadBalancers']:
                return build_evaluation(load_balancer_arn, 'NOT_APPLICABLE', 'Load balancer not found')
            
            load_balancer = lb_response['LoadBalancers'][0]
            lb_name = load_balancer.get('LoadBalancerName', 'Unknown')
            logger.info(f"Evaluating load balancer: {lb_name}")
            
        except ClientError as e:
            error_code = e.response['Error']['Code']
            logger.warning(f"ClientError getting load balancer {load_balancer_arn}: {error_code}")
            
            if error_code in ['LoadBalancerNotFound', 'InvalidLoadBalancerArn']:
                return build_evaluation(load_balancer_arn, 'NOT_APPLICABLE', 'Load balancer not found')
            elif error_code in ['AccessDenied', 'UnauthorizedOperation']:
                return build_evaluation(load_balancer_arn, 'NOT_APPLICABLE', 'Access denied to load balancer')
            elif error_code in ['Throttling', 'RequestLimitExceeded']:
                return build_evaluation(load_balancer_arn, 'NOT_APPLICABLE', 'Service throttling - retry later')
            else:
                return build_evaluation(load_balancer_arn, 'NOT_APPLICABLE', f'Service error: {error_code}')
        
        # Get listeners for this load balancer
        try:
            listeners_response = client.describe_listeners(LoadBalancerArn=load_balancer_arn)
            
        except ClientError as e:
            error_code = e.response['Error']['Code']
            logger.warning(f"ClientError getting listeners for {load_balancer_arn}: {error_code}")
            
            if error_code in ['LoadBalancerNotFound', 'ListenerNotFound']:
                return build_evaluation(load_balancer_arn, 'NOT_APPLICABLE', 'Load balancer or listeners not found')
            elif error_code in ['AccessDenied', 'UnauthorizedOperation']:
                return build_evaluation(load_balancer_arn, 'NOT_APPLICABLE', 'Access denied to listeners')
            else:
                return build_evaluation(load_balancer_arn, 'NOT_APPLICABLE', f'Listener service error: {error_code}')
        
        # Check secure listeners
        secure_listeners = []
        for listener in listeners_response['Listeners']:
            if listener['Protocol'] in ['HTTPS', 'TLS', 'TCP_SSL']:
                ssl_policy = listener.get('SslPolicy', 'None')
                secure_listeners.append({
                    'ListenerArn': listener['ListenerArn'],
                    'Protocol': listener['Protocol'],
                    'Port': listener['Port'],
                    'SslPolicy': ssl_policy
                })
        
        if not secure_listeners:
            return build_evaluation(load_balancer_arn, 'NOT_APPLICABLE', 'No HTTPS/TLS listeners found')
        
        # Perform binary check based on check_type
        if check_type == 'PQC':
            return evaluate_pqc_compliance(load_balancer_arn, lb_name, secure_listeners)
        elif check_type == 'LEGACY_TLS':
            return evaluate_legacy_tls_compliance(load_balancer_arn, lb_name, secure_listeners)
        else:
            return build_evaluation(load_balancer_arn, 'NOT_APPLICABLE', f'Unknown check type: {check_type}')
            
    except Exception as e:
        logger.error(f"Unexpected error evaluating load balancer {load_balancer_arn}: {str(e)}", exc_info=True)
        error_msg = str(e)[:200] + "..." if len(str(e)) > 200 else str(e)
        return build_evaluation(load_balancer_arn, 'NOT_APPLICABLE', f'Evaluation error: {error_msg}')

def evaluate_pqc_compliance(load_balancer_arn, lb_name, secure_listeners):
    """
    Evaluates if all secure listeners use PQC-ready policies.
    Classifies each listener into Tier 1, Tier 2, or Tier 3.
    COMPLIANT: All listeners use policies in ELB_PQC_POLICIES (Tier 1 or Tier 2)
    NON_COMPLIANT: At least one listener uses a non-PQC policy (Tier 3)
    """
    non_compliant_listeners = []
    compliant_tiers = []
    
    for listener in secure_listeners:
        ssl_policy = listener['SslPolicy']
        tier = get_policy_tier(ssl_policy)
        
        if tier == 3:
            non_compliant_listeners.append({
                'port': listener['Port'],
                'policy': ssl_policy
            })
        else:
            compliant_tiers.append(tier)
    
    if non_compliant_listeners:
        # At least one listener is Tier 3 (not PQ-ready)
        if len(non_compliant_listeners) == 1:
            policy = non_compliant_listeners[0]['policy']
            port = non_compliant_listeners[0]['port']
            recommended = get_elb_recommended_policy(policy)
            annotation = f"Listener on port {port} is Tier 3 (not PQ-ready): {policy}. Recommended: {recommended}"
        else:
            policies = list(set(l['policy'] for l in non_compliant_listeners))
            # Use first non-compliant policy to determine FIPS recommendation
            recommended = get_elb_recommended_policy(policies[0])
            annotation = f"{len(non_compliant_listeners)} listeners are Tier 3 (not PQ-ready): {policies}. Recommended: {recommended}"
        
        return build_evaluation(load_balancer_arn, 'NON_COMPLIANT', annotation)
    else:
        # All listeners are PQ-ready (Tier 1 or Tier 2)
        min_tier = min(compliant_tiers) if compliant_tiers else 2
        max_tier = max(compliant_tiers) if compliant_tiers else 2
        
        if len(secure_listeners) == 1:
            tier = compliant_tiers[0]
            policy = secure_listeners[0]['SslPolicy']
            if tier == 1:
                annotation = f"Listener is Tier 1 (PQ-ready, TLS 1.3 only): {policy}"
            else:
                annotation = f"Listener is Tier 2 (PQ-ready, backward compatible): {policy}"
        else:
            if min_tier == max_tier:
                if min_tier == 1:
                    annotation = f"All {len(secure_listeners)} listeners are Tier 1 (PQ-ready, TLS 1.3 only)"
                else:
                    annotation = f"All {len(secure_listeners)} listeners are Tier 2 (PQ-ready, backward compatible)"
            else:
                annotation = f"All {len(secure_listeners)} listeners are PQ-ready (Tier 1: {compliant_tiers.count(1)}, Tier 2: {compliant_tiers.count(2)})"
        
        return build_evaluation(load_balancer_arn, 'COMPLIANT', annotation)

def evaluate_legacy_tls_compliance(load_balancer_arn, lb_name, secure_listeners):
    """
    Evaluates if any secure listeners allow TLS 1.0 or 1.1.
    COMPLIANT: No listeners use policies in ELB_LEGACY_TLS_POLICIES
    NON_COMPLIANT: At least one listener allows TLS 1.0 or 1.1
    """
    legacy_listeners = []
    
    for listener in secure_listeners:
        ssl_policy = listener['SslPolicy']
        if ssl_policy in ELB_LEGACY_TLS_POLICIES:
            legacy_listeners.append({
                'port': listener['Port'],
                'policy': ssl_policy
            })
    
    if legacy_listeners:
        # At least one listener allows legacy TLS
        policies = [l['policy'] for l in legacy_listeners]
        unique_policies = list(set(policies))
        
        if len(legacy_listeners) == 1:
            annotation = f"Listener on port {legacy_listeners[0]['port']} allows TLS 1.0 or TLS 1.1: {legacy_listeners[0]['policy']}. HIGH PRIORITY: Upgrade to policy without TLS 1.0 or TLS 1.1 support"
        else:
            annotation = f"{len(legacy_listeners)} listeners allow TLS 1.0 or TLS 1.1: {unique_policies}. HIGH PRIORITY: Eliminate legacy TLS support"
        
        return build_evaluation(load_balancer_arn, 'NON_COMPLIANT', annotation)
    else:
        # No listeners allow legacy TLS
        if len(secure_listeners) == 1:
            annotation = f"Listener does not allow TLS 1.0 or TLS 1.1. Policy: {secure_listeners[0]['SslPolicy']}"
        else:
            annotation = f"All {len(secure_listeners)} listeners do not allow TLS 1.0 or TLS 1.1"
        
        return build_evaluation(load_balancer_arn, 'COMPLIANT', annotation)

def build_evaluation(resource_id, compliance_type, annotation):
    """
    Builds an AWS Config evaluation result.
    Uses Unix timestamp to avoid JSON serialization issues.
    """
    # Ensure annotation fits AWS Config limits (256 characters max)
    if len(annotation) > 250:
        annotation = annotation[:247] + "..."
    
    return {
        'ComplianceResourceType': 'AWS::ElasticLoadBalancingV2::LoadBalancer',
        'ComplianceResourceId': resource_id,
        'ComplianceType': compliance_type,
        'Annotation': annotation,
        'OrderingTimestamp': time.time()
    }
