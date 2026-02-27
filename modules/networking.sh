#!/usr/bin/env bash

# Argument:
# $1 - Security Group ID
list_resource_using_security_group() {
    local SG_ID="$1"

    log_info "Listing resources using Security Group ID: $SG_ID"

    log_info "EC2 Instances:"

    aws ec2 describe-instances \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --filters "Name=instance.group-id,Values=$SG_ID" \
        --query "Reservations[].Instances[].InstanceId" \
        --output text

    log_info "Network Interfaces (ENIs):"
    # This is useful because many AWS services (e.g., Lambda, RDS, ECS) attach SGs indirectly via ENIs.

    aws ec2 describe-network-interfaces \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --filters "Name=group-id,Values=$SG_ID" \
        --query "NetworkInterfaces[].{ID:NetworkInterfaceId,Type:InterfaceType,Description:Description,Attachment:Attachment.InstanceId}" \
        --output table

    log_info "Classic Load Balancers (ELB):"

    aws elb describe-load-balancers \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --query "LoadBalancerDescriptions[?SecurityGroups && contains(SecurityGroups, '$SG_ID')].[LoadBalancerName]" \
        --output text

    log_info "Application/Network Load Balancers (ALB/NLB):"

    aws elbv2 describe-load-balancers \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --query "LoadBalancers[?SecurityGroups && contains(SecurityGroups, '$SG_ID')].[LoadBalancerArn]" \
        --output text

    log_info "RDS Instances:"

    aws rds describe-db-instances \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --query "DBInstances[?VpcSecurityGroups[?VpcSecurityGroupId=='$SG_ID']].DBInstanceIdentifier" \
        --output text

    log_info "Lambda Functions:"

    # This lists ALL lambda functions in given region; we need to filter them!
    # or use:   --query "Functions[].FunctionName" --output text | tr '\t' '\n'
    # aws lambda list-functions \
    #     --profile "$AWS_PROFILE" \
    #     --region "$AWS_REGION" \
    #     --output json | jq -r '.Functions[].FunctionName'

    # The output (list of function names) is piped to xargs, which will run a command for each function name.
    # -n1 tells xargs to run the command once per input line (i.e., per function).
    # -I{} replaces {} in the command with the function name.
    aws lambda list-functions --profile "$AWS_PROFILE" --region "$AWS_REGION" --query "Functions[].FunctionName" --output text | \
        xargs -n1 -I{} sh -c "aws lambda get-function-configuration --profile \"\$1\" --region \"\$2\" --function-name \"\$3\" \
        --query \"VpcConfig.SecurityGroupIds\" --output text 2>/dev/null | grep -w \"\$4\" && echo \"Found in Lambda function: \$3\"" _ "$AWS_PROFILE" "$AWS_REGION" {} "$SG_ID"

    log_info "ECS Services and Tasks:"

    aws ecs list-clusters --profile "$AWS_PROFILE" --region "$AWS_REGION" --query "clusterArns[]" --output text | tr '\t' '\n' | while read cluster; do
        aws ecs list-services --profile "$AWS_PROFILE" --region "$AWS_REGION" --cluster $cluster --query "serviceArns[]" --output text | tr '\t' '\n' | while read service; do
            aws ecs describe-services --profile "$AWS_PROFILE" --region "$AWS_REGION" --cluster $cluster --services $service \
                --query "services[].networkConfiguration.awsvpcConfiguration.securityGroups[]" \
                --output text | grep $SG_ID && echo "Found in ECS service: $service"
        done
    done
}

networking() {
    list_resource_using_security_group "$SG_ID"
}
