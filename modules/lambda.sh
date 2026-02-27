#!/usr/bin/env bash

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

list_most_recently_invoked_lambda_functions() {
    # local limit="${1:-10}"

    # aws lambda list-functions \
    #     --profile "$AWS_PROFILE" \
    #     --region "$AWS_REGION" \
    #     --query "Functions[].FunctionName" \
    #     --output text | tr '\t' '\n' | \
    # while read function_name; do
    #     last_invoked=$(aws cloudwatch get-metric-statistics \
    #         --profile "$AWS_PROFILE" \
    #         --region "$AWS_REGION" \
    #         --namespace AWS/Lambda \
    #         --metric-name Invocations \
    #         --dimensions Name=FunctionName,Value="$function_name" \
    #         --statistics Sum \
    #         --period 86400 \
    #         --start-time "$(date -u -v-30d +%Y-%m-%dT%H:%M:%SZ)" \
    #         --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    #         --query "Datapoints | sort_by(@, &Timestamp) | [-1].Timestamp" \
    #         --output text)
    #     echo -e "$last_invoked\t$function_name"
    # done | sort -r | head -n "$limit" | column -t -s $'\t'

    # \
    # | jq -r '
    #     .[]
    #     | select(.LastEvent != null)
    #     | [.Function, (.LastEvent / 1000 | strftime("%Y-%m-%d %H:%M:%S"))]
    #     | @tsv
    #     ' \
    # | sort -k2 -r \
    # | awk 'BEGIN {printf "%-20s  %s\n", "LAST EVENT TIME", "FUNCTION NAME"} {printf "%-20s  %s\n", $2" "$3, $1}'

    #!/bin/bash
    # Lists AWS Lambda functions sorted by most recent invocation (based on CloudWatch log timestamps)
    # Requires AWS CLI configured with permissions for CloudWatch Logs and Lambda.

    log_wait "Fetching Lambda invocation activity... (this may take a few seconds)"
}

lambda() {
    list_lambda_log_group_subscription_filters
    list_all_lambda_functions
    replace_lambda_log_group_subscription_filters "$OLD_FILTER_DESTINATION_ARN" "$NEW_FILTER_NAME" "$NEW_FILTER_DESTINATION_ARN" "$AWS_CLOUDWATCH_TO_KINESIS_ROLE_ARN"
    list_most_recently_invoked_lambda_functions 20
}