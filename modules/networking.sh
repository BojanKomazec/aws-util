#!/usr/bin/env bash

list_vpcs() {
    log_info "Listing VPCs in region $AWS_REGION:"
    # list VPCs with their ID, CIDR block, state, name and whether they have an Internet Gateway attached (based on attachments)
    aws ec2 describe-vpcs \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query "Vpcs[].{ID: VpcId, CIDR: CidrBlock, State: State, Name: Tags[?Key=='Name']|[0].Value}" \
    --output table
}

list_subnets() {
    local VPC_ID

    if ! VPC_ID=$(prompt_user_for_value "VPC ID (e.g., vpc-0123456789abcdef0)"); then
        echo "VPC ID is required. Aborting."
        return 1
    fi

    _list_subnets "$VPC_ID"
}

_list_subnets() {
    local VPC_ID="$1"

    log_info "Listing subnets in VPC $VPC_ID in region $AWS_REGION:"

    # list subnets with their ID, CIDR block, state, AZ, name and whether they are public or private (based on route table associations)
    aws ec2 describe-subnets \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "Subnets[].{ID:SubnetId,CIDR:CidrBlock,State:State,AZ:AvailabilityZone,Name:Tags[?Key=='Name']|[0].Value,Public:MapPublicIpOnLaunch}" \
        --output table
}

list_internet_gateways() {
    log_info "Listing Internet Gateways in region $AWS_REGION:"
    aws ec2 describe-internet-gateways --profile "$AWS_PROFILE" --region "$AWS_REGION" --query "InternetGateways[].{ID:InternetGatewayId,State:Attachments[0].State}" --output table
}

list_nat_gateways() {
    log_info "Listing NAT Gateways in region $AWS_REGION:"
    aws ec2 describe-nat-gateways --profile "$AWS_PROFILE" --region "$AWS_REGION" --query "NatGateways[].{ID:NatGatewayId,State:State}" --output table
}

list_route_tables() {
    log_info "Listing Route Tables in region $AWS_REGION:"
    aws ec2 describe-route-tables --profile "$AWS_PROFILE" --region "$AWS_REGION" --query "RouteTables[].{ID:RouteTableId,VPC:VpcId}" --output table
}

list_security_groups() {
    log_info "Listing Security Groups in region $AWS_REGION:"
    aws ec2 describe-security-groups --profile "$AWS_PROFILE" --region "$AWS_REGION" --query "SecurityGroups[].{ID:GroupId,Name:GroupName,Description:Description}" --output table
}

list_classic_load_balancers() {
    log_info "Listing Classic Load Balancers in region $AWS_REGION:"
    aws elb describe-load-balancers --profile "$AWS_PROFILE" --region "$AWS_REGION" --query "LoadBalancerDescriptions[].{Name:LoadBalancerName,DNSName:DNSName}" --output table
}

list_application_load_balancers() {
    log_info "Listing Application/Network Load Balancers in region $AWS_REGION:"
    aws elbv2 describe-load-balancers --profile "$AWS_PROFILE" --region "$AWS_REGION" --query "LoadBalancers[].{Name:LoadBalancerName,DNSName:DNSName}" --output table
}

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

networking_menu() {
    local options=(
        "List VPCs"
        "List subnets"
        "List Internet Gateways"
        "List NAT Gateways"
        "List Route Tables"
        "List Security Groups"
        "List Classic Load Balancers"
        "List Application/Network Load Balancers"
        "List resources using security group"
        "EXIT"
    )

    while true; do
        log_empty_line
        show_menu_select_message "Networking"
        select option in "${options[@]}"; do
            if [[ -n "$option" ]]; then
                log_info "Selected option: $option\n"
                case $option in
                    "List VPCs")
                        list_vpcs
                        ;;
                    "List subnets")
                        list_subnets
                        ;;
                    "List Internet Gateways")
                        list_internet_gateways
                        ;;
                    "List NAT Gateways")
                        list_nat_gateways
                        ;;
                    "List Route Tables")
                        list_route_tables
                        ;;
                    "List Security Groups")
                        list_security_groups
                        ;;
                    "List Classic Load Balancers")
                        list_classic_load_balancers
                        ;;
                    "List Application/Network Load Balancers")
                        list_application_load_balancers
                        ;;
                    "List resources using security group")
                        local SG_ID
                        if ! SG_ID=$(prompt_user_for_value "Security Group ID (e.g., sg-0123456789abcdef0)"); then
                            echo "Security Group ID is required. Aborting."
                            return 1
                        fi
                        list_resource_using_security_group "$SG_ID"
                        ;;
                    "EXIT")
                        log_info "Exiting Networking menu."
                        return 0
                        ;;
                    *)
                        log_error "Invalid option"
                        ;;
                esac
                break
            else
                log_error "Invalid selection. Please choose a valid option."
            fi
        done
    done
}
