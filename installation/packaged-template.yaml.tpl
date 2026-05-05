AWSTemplateFormatVersion: '2010-09-09'
Description: 'PQC and Legacy TLS Config Scanner - Native CloudFormation template for StackSets deployment'

Resources:
  # IAM Role for ELB Compliance Function
  ELBComplianceFunctionRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: lambda.amazonaws.com
            Action: sts:AssumeRole
      Policies:
        - PolicyName: ELBCompliancePolicy
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - elasticloadbalancing:DescribeLoadBalancers
                  - elasticloadbalancing:DescribeListeners
                  - config:PutEvaluations
                Resource: '*'
              - Effect: Allow
                Action:
                  - logs:CreateLogGroup
                  - logs:CreateLogStream
                  - logs:PutLogEvents
                Resource: !Sub 'arn:aws:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/lambda/pqc-elb-compliance:*'

  # IAM Role for API Gateway Compliance Function
  APIGatewayComplianceFunctionRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: lambda.amazonaws.com
            Action: sts:AssumeRole
      Policies:
        - PolicyName: APIGatewayCompliancePolicy
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - apigateway:GET
                Resource:
                  - !Sub 'arn:aws:apigateway:${AWS::Region}::/restapis/*'
                  - !Sub 'arn:aws:apigateway:${AWS::Region}::/apis/*'
              - Effect: Allow
                Action:
                  - config:PutEvaluations
                Resource: '*'
              - Effect: Allow
                Action:
                  - logs:CreateLogGroup
                  - logs:CreateLogStream
                  - logs:PutLogEvents
                Resource: !Sub 'arn:aws:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/lambda/pqc-apigw-compliance:*'

  # ELB Compliance Lambda Function
  ELBComplianceFunction:
    Type: AWS::Lambda::Function
    Properties:
      FunctionName: pqc-elb-compliance
      Runtime: python3.12
      Handler: elb-pqc.lambda_handler
      Timeout: 300
      MemorySize: 256
      TracingConfig:
        Mode: Active
      Environment:
        Variables:
          LOG_LEVEL: INFO
      Role: !GetAtt ELBComplianceFunctionRole.Arn
      Code:
        S3Bucket: __LAMBDA_CODE_BUCKET__
        S3Key: __ELB_LAMBDA_CODE_KEY__

  # API Gateway Compliance Lambda Function
  APIGatewayComplianceFunction:
    Type: AWS::Lambda::Function
    Properties:
      FunctionName: pqc-apigw-compliance
      Runtime: python3.12
      Handler: api-gateway-pqc.lambda_handler
      Timeout: 300
      MemorySize: 256
      TracingConfig:
        Mode: Active
      Environment:
        Variables:
          LOG_LEVEL: INFO
      Role: !GetAtt APIGatewayComplianceFunctionRole.Arn
      Code:
        S3Bucket: __LAMBDA_CODE_BUCKET__
        S3Key: __APIGW_LAMBDA_CODE_KEY__

  # Lambda Permissions for Config Service
  ELBPQCLambdaConfigPermission:
    Type: AWS::Lambda::Permission
    Properties:
      FunctionName: !Ref ELBComplianceFunction
      Action: lambda:InvokeFunction
      Principal: config.amazonaws.com
      SourceAccount: !Ref AWS::AccountId

  ELBLegacyTLSLambdaConfigPermission:
    Type: AWS::Lambda::Permission
    Properties:
      FunctionName: !Ref ELBComplianceFunction
      Action: lambda:InvokeFunction
      Principal: config.amazonaws.com
      SourceAccount: !Ref AWS::AccountId

  APIGatewayPQCLambdaConfigPermission:
    Type: AWS::Lambda::Permission
    Properties:
      FunctionName: !Ref APIGatewayComplianceFunction
      Action: lambda:InvokeFunction
      Principal: config.amazonaws.com
      SourceAccount: !Ref AWS::AccountId

  APIGatewayLegacyTLSLambdaConfigPermission:
    Type: AWS::Lambda::Permission
    Properties:
      FunctionName: !Ref APIGatewayComplianceFunction
      Action: lambda:InvokeFunction
      Principal: config.amazonaws.com
      SourceAccount: !Ref AWS::AccountId

Outputs:
  ELBComplianceFunctionArn:
    Description: 'ARN of the ELB compliance scanner Lambda function'
    Value: !GetAtt ELBComplianceFunction.Arn
    Export:
      Name: !Sub '${AWS::StackName}-ELBFunction'

  APIGatewayComplianceFunctionArn:
    Description: 'ARN of the API Gateway compliance scanner Lambda function'
    Value: !GetAtt APIGatewayComplianceFunction.Arn
    Export:
      Name: !Sub '${AWS::StackName}-APIGatewayFunction'
