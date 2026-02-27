#!/usr/bin/env bash

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
# --query 'logGroups[*].{Function:logGroupName,LastEvent:lastEventTimestamp}' \
# Output contains creationTime which is in milliseconds. 
list_cloudwatch_log_groups() {
    aws logs describe-log-groups \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --log-group-name-prefix "/aws/lambda/" \
    --output json
}

# Returns a JSON object with a single field: queryId
start_aws_logs_query() {
    local logGroupName="$1"
    local startTime="$2"
    local endTime="$3"
    local searchString="$4"

    aws logs start-query \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --log-group-name "$logGroupName" \
    --start-time "$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$startTime" +%s)" \
    --end-time "$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$endTime" +%s)" \
    --query-string "fields @timestamp, @message | filter @message like /$searchString/ | stats count()" | jq -r '.queryId'
}

find_count_of_cloudwatch_logs_containing_string() {
    local logGroupName="$1"
    local startTime="$2"
    local endTime="$3"
    local searchString="$4"
    local queryId
    local quieryResultJson

    if [[ -z "$logGroupName" ]]; then
        while true; do
            if ! logGroupName=$(prompt_user_for_value "Log group name"); then
                log_error "Log group name is required!"
                continue
            else
                break
            fi
        done
    fi

    if [[ -z "$startTime" ]]; then
        while true; do
            if ! startTime=$(prompt_user_for_value "Start time (e.g., 2025-11-11T11:00:00Z)"); then
                log_error "Start time is required!"
                continue
            else
                break
            fi
        done
    fi

    if [[ -z "$endTime" ]]; then
        while true; do
            if ! endTime=$(prompt_user_for_value "End time (e.g., 2025-11-11T12:00:00Z)"); then
                log_error "End time is required!"
                continue
            else
                break
            fi
        done
    fi

    if [[ -z "$searchString" ]]; then
        while true; do
            if ! searchString=$(prompt_user_for_value "Search string"); then
                log_error "Search string is required!"
                continue
            else
                break
            fi
        done
    fi

    queryId="$(start_aws_logs_query "$logGroupName" "$startTime" "$endTime" "$searchString")"


    while true; do
        quieryResultJson=$(aws logs get-query-results \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            --query-id "$queryId")

        local queryStatus
        queryStatus=$(echo "$quieryResultJson" | jq -r '.status')

        if [[ "$queryStatus" == "Complete" ]]; then
            log_success "Query completed. Result:\n$quieryResultJson"
            break
        fi

        log_info "Query status: $queryStatus. Waiting for 5 seconds before checking again..."
        sleep 5
    done
}

cloudwatch_logs() {
    list_cloudwatch_log_groups
    find_count_of_cloudwatch_logs_containing_string "" "" "" ""
    find_count_of_cloudwatch_logs_containing_string "/aws/lambda/eck-esf-prod" "2025-11-12T12:00:00Z" "2025-11-12T13:00:00Z" "document_parsing_exception"
    find_count_of_cloudwatch_logs_containing_string "/aws/lambda/eck-esf-prod" "2025-11-11T12:00:00Z" "2025-11-11T13:00:00Z" "document_parsing_exception"
    find_count_of_cloudwatch_logs_containing_string "/aws/lambda/eck-esf-prod" "2025-11-12T12:00:00Z" "2025-11-12T13:00:00Z" "document_parsing_exception"
}