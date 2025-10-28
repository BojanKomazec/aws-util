#!/usr/bin/env bash
# shellcheck disable=SC1090

bash_import() {
    local repo="$1"
    local path="$2"
    local version="${3:-main}"
    local url="https://raw.githubusercontent.com/$repo/refs/heads/$version/$path"
    # echo "Importing $url"
    source <(curl -fsSL "$url")
}

bash_import "BojanKomazec/bash-util" "log.sh"
bash_import "BojanKomazec/bash-util" "config.sh"
bash_import "BojanKomazec/bash-util" "cli.sh"
bash_import "BojanKomazec/bash-util" "user_input.sh"

VERBOSE=true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if AWS credentials are configured
# Use e.g. aws sso login --profile <profile>
check_aws_credentials() {
    local profile="${AWS_PROFILE:-default}"
    log_info "Verifying AWS credentials for profile: $profile"

    if ! aws sts get-caller-identity --profile "$profile" &> /dev/null; then
        log_error "AWS credentials not configured or invalid."
        return 1
    fi

    return 0
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

list_all_lambda_functions() {
    local output
    local exit_code
    output=$(aws lambda list-functions \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --query "Functions[].FunctionName" \
        --output text 2>&1)

    exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log_error "Failed to list Lambda functions.\nError: $output"
        return 1
    fi

    lambda_names=()
    # Normalize output. Original output contains TAB-delimited lambda names.
    # We want to have each lambda name in a new line.
    # Split tab-delimited output into array.
    readarray -t lambda_names <<< "$(echo "$output" | tr '\t' '\n')"

    log_array_elements true "${lambda_names[@]}"
}

# If reserved_concurrent_executions is set to -1, it means that the function has unreserved concurrency,
# meaning it can scale up to account level concurrency limit.
# If it is set to 0, the function is effectively disabled.
# Any positive integer value indicates the maximum number of concurrent executions for the function.
reserve_lambda_concurrency() {
    local function_name="$1"
    local reserved_concurrent_executions="$2"

    local output
    local exit_code

    log_info "Reserving $reserved_concurrent_executions concurrent executions for Lambda function: $function_name"

    output=$(aws lambda put-function-concurrency \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --function-name "$function_name" \
        --reserved-concurrent-executions "$reserved_concurrent_executions" 2>&1)

    exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log_error "Failed to reserve concurrency for Lambda function: $function_name\nError: $output"
        return 1
    fi

    log_success "Successfully reserved concurrency for Lambda function: $function_name"
}

# Removes a concurrent execution limit from a function.
remove_lambda_concurrency() {
    local function_name="$1"

    log_info "Removing concurrency limit for Lambda function: $function_name"

    output=$(aws lambda delete-function-concurrency \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --function-name "$function_name" 2>&1)

    exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log_error "Failed to remove concurrency limit for Lambda function: $function_name\nError: $output"
        return 1
    fi

    log_success "Successfully removed concurrency limit for Lambda function: $function_name"
}

list_log_group_subscription_filters() {
    local log_group="$1"
    log_info "Log Group: $log_group"

    aws logs describe-subscription-filters \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --log-group-name "$log_group" \
        --query 'subscriptionFilters[].{Name:filterName,Destination:destinationArn}' \
        --output table

    log_empty_line
}

replace_log_group_subscription_filter() {
    local log_group="$1"
    local old_filter_destination_arn="$2"
    local new_filter_name="$3"
    local new_filter_destination_arn="$4"
    local new_filter_role_arn="$5"

    log_info "Log Group: $log_group"

    # Get subscription filters
    filters_json=$(aws logs describe-subscription-filters \
      --region "$AWS_REGION" \
      --profile "$AWS_PROFILE" \
      --log-group-name "$log_group" \
      --query 'subscriptionFilters' \
      --output json)

    # Skip if no filters
    if [ "$filters_json" == "[]" ]; then
      return
    fi

    # Iterate over filters
    while read -r filter; do
      local dest_arn=$(echo "$filter" | jq -r '.destinationArn')
      local filter_name=$(echo "$filter" | jq -r '.filterName')
      local filter_pattern=$(echo "$filter" | jq -r '.filterPattern')

      if [[ "$dest_arn" == "$old_filter_destination_arn" ]]; then
        log_info " → Found old destination: $dest_arn"
        log_info " → Replacing with: $new_filter_destination_arn"

        local output
        local exit_code
        local user_confirmed

        user_confirmed=$(prompt_user_for_confirmation "❓ Do you want to proceed with deleting the subscription filter for log group '$log_group'?" "n")
        if [[ "$user_confirmed" == "true" ]]; then
            # Delete old filter
            output=$(aws logs delete-subscription-filter \
            --region "$AWS_REGION" \
            --profile "$AWS_PROFILE" \
            --log-group-name "$log_group" \
            --filter-name "$filter_name" 2>&1)

            exit_code=$?

            if [ $exit_code -ne 0 ]; then
                log_error "Failed to delete subscription for $log_group.\nError: $output"
            else
                log_success "Successfully deleted subscription for $log_group"
            fi
        else
            log_warning "Skipping deletion of the subscription filter for log group: $log_group"
        fi

        log_empty_line

        user_confirmed=$(prompt_user_for_confirmation "❓ Do you want to proceed with creating the new subscription filter for log group '$log_group'?" "n")
        if [[ "$user_confirmed" == "true" ]]; then
            # Create new filter
            output=$(aws logs put-subscription-filter \
            --region "$AWS_REGION" \
            --profile "$AWS_PROFILE" \
            --log-group-name "$log_group" \
            --filter-name "$new_filter_name" \
            --filter-pattern "$filter_pattern" \
            --destination-arn "$new_filter_destination_arn" \
            --role-arn "$new_filter_role_arn" 2>&1)

            exit_code=$?

            if [ $exit_code -ne 0 ]; then
                log_error "Failed to create subscription for $log_group.\nError: $output"
            else
                log_success "Successfully created subscription for $log_group"
            fi
        else
            log_warning "Skipping creation of new subscription for log group: $log_group"
        fi

        log_empty_line
      fi
    done < <(jq -c '.[]' <<< "$filters_json")
}

list_lambda_log_group_subscription_filters() {
    aws logs describe-log-groups \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --log-group-name-prefix "/aws/lambda/" \
        --query 'logGroups[].logGroupName' \
        --output text | tr '\t' '\n' |
    while read log_group; do
        list_log_group_subscription_filters "$log_group"
    done
}

replace_lambda_log_group_subscription_filters() {
    local old_filter_destination_arn="$1"
    local new_filter_name="$2"
    local new_filter_destination_arn="$3"
    local new_filter_role_arn="$4"

    aws logs describe-log-groups \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --log-group-name-prefix "/aws/lambda/" \
        --query 'logGroups[].logGroupName' \
        --output text | tr '\t' '\n' |
    while read log_group; do
        replace_log_group_subscription_filter "$log_group" "$old_filter_destination_arn" "$new_filter_name" "$new_filter_destination_arn" "$new_filter_role_arn"
    done
}

main() {
    echo "SCRIPT_DIR = $SCRIPT_DIR"  >&2

    load_env_file "$SCRIPT_DIR/.env"
    log_info "AWS_PROFILE=$AWS_PROFILE"
    log_info "AWS_REGION=$AWS_REGION"
    log_info "SG_ID=$SG_ID"
    log_info "OLD_FILTER_DESTINATION_ARN=$OLD_FILTER_DESTINATION_ARN"
    log_info "NEW_FILTER_NAME=$NEW_FILTER_NAME"
    log_info "NEW_FILTER_DESTINATION_ARN=$NEW_FILTER_DESTINATION_ARN"
    log_info "AWS_CLOUDWATCH_TO_KINESIS_ROLE_ARN=$AWS_CLOUDWATCH_TO_KINESIS_ROLE_ARN"

    check_if_command_tool_is_available "aws" || exit 1
    check_aws_credentials || exit 1

    # list_resource_using_security_group "$SG_ID"
    # list_lambda_log_group_subscription_filters
    list_all_lambda_functions
    # replace_lambda_log_group_subscription_filters "$OLD_FILTER_DESTINATION_ARN" "$NEW_FILTER_NAME" "$NEW_FILTER_DESTINATION_ARN" "$AWS_CLOUDWATCH_TO_KINESIS_ROLE_ARN"
}

main
