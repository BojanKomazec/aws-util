#!/usr/bin/env bash

source ./util.sh

# Consider renaming this module to identity_center.sh or identity_services.sh in the future, as it includes both IAM
# and IAM Identity Center (SSO) related functions. Alternatively, we could split it into two separate modules:
# iam.sh for IAM and identity_center.sh for IAM Identity Center (SSO).

#
# IAM
#

list_iam_users() {
    log_empty_line
    log_info "Listing IAM users:"
    aws iam list-users \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --output table
}

# --output table
list_iam_roles() {
    log_empty_line
    log_info "Listing IAM roles:"
    aws iam list-roles \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --query 'Roles[].{Name:RoleName, Created:CreateDate}' \
        --output table
}

list_iam_policies() {
    log_empty_line
    log_info "Listing IAM policies:"
    aws iam list-policies \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --output table
}

list_iam_groups() {
    log_empty_line
    log_info "Listing IAM groups:"
    aws iam list-groups \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --output table
}

list_iam_users_in_group() {
    log_empty_line
    log_info "Listing IAM users in a specific group:"
    local group_name
    if ! group_name=$(prompt_user_for_value "Group name"); then
        log_error "Group name is required!"
        return 1
    fi
    aws iam get-group \
        --group-name "$group_name" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --output table
}

list_iam_roles_in_group() {
    log_empty_line
    log_info "Listing IAM roles in a specific group:"
    local group_name
    if ! group_name=$(prompt_user_for_value "Group name"); then
        log_error "Group name is required!"
        return 1
    fi
    aws iam get-group \
        --group-name "$group_name" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --output table
}

show_iam_role_details() {
    log_empty_line
    log_info "Showing details of a specific IAM role:"
    local role_name
    if ! role_name=$(prompt_user_for_value "Role name"); then
        log_error "Role name is required!"
        return 1
    fi
    aws iam get-role \
        --role-name "$role_name" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --output table
}

show_iam_user_details() {
    log_empty_line
    log_info "Showing details of a specific IAM user:"
    local user_name
    if ! user_name=$(prompt_user_for_value "User name"); then
        log_error "User name is required!"
        return 1
    fi
    aws iam get-user \
        --user-name "$user_name" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --output table
}

lookup_assume_role_events() {
    log_empty_line

    # Get the timestamp for 1 hour ago (Linux/macOS)
    START_TIME=$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)

    log_wait "Looking up AssumeRoleWithWebIdentity events in CloudTrail from $START_TIME to now:"

    # if necessary, use --max-results 1000 \
    aws cloudtrail lookup-events \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
        --start-time "$START_TIME" \
        --query "Events[].{Time:EventTime, Session:CloudTrailEvent}" \
        --output json
}

watch_assume_role_events() {
    log_empty_line
    log_info "Watching for new AssumeRoleWithWebIdentity events in CloudTrail (press Ctrl+C to stop):"

    # if necessary, use --max-results 1000 \
    aws cloudtrail lookup-events \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
        | jq '.Events[].CloudtrailEvent | fromjson'
}

#
# IAM Identity Center (SSO)
#

list_identity_stores() {
    log_empty_line
    log_info "Listing Identity Stores:"
    aws sso-admin list-instances \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --output table
}

_list_iam_ic_users() {
    local identity_store_id="$1"

    log_empty_line
    log_info "Listing IAM Identity Center users in Identity Store $identity_store_id:"

    aws identitystore list-users \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --identity-store-id "$identity_store_id" \
        --query 'Users[].{UserName:UserName, DisplayName:DisplayName, UserId:UserId}' \
        --output table
}

list_iam_ic_users() {
    local identity_store_id
    if ! identity_store_id=$(prompt_user_for_value "Identity Store ID"); then
        log_error "Identity Store ID is required!"
        return 1
    fi

    _list_iam_ic_users "$identity_store_id"
}

_show_details_of_iam_ic_user() {
    local identity_store_id="$1"
    local user_id="$2"

    log_empty_line
    log_info "Showing details of IAM Identity Center user $user_id in Identity Store $identity_store_id:"

    aws identitystore describe-user \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --identity-store-id "$identity_store_id" \
        --user-id "$user_id" \
        --output table

    local group_memberships
    group_memberships=$(aws identitystore list-group-memberships-for-member \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --identity-store-id "$identity_store_id" \
        --member-id "UserId=$user_id" \
        --query 'GroupMemberships[].GroupId' \
        --output text)

    if [ -n "$group_memberships" ]; then
        log_empty_line
        log_info "User is a member of the following groups:"
        for group_id in $group_memberships; do
            aws identitystore describe-group \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --identity-store-id "$identity_store_id" \
                --group-id "$group_id" \
                --query '{GroupName:DisplayName, GroupId:GroupId}' \
                --output table
        done
    else
        log_empty_line
        log_info "User is not a member of any groups."
    fi
}

show_details_of_iam_ic_user() {
    local identity_store_id
    if ! identity_store_id=$(prompt_user_for_value "Identity Store ID"); then
        log_error "Identity Store ID is required!"
        return 1
    fi

    local user_id
    if ! user_id=$(prompt_user_for_value "User ID"); then
        log_error "User ID is required!"
        return 1
    fi

    _show_details_of_iam_ic_user "$identity_store_id" "$user_id"
}

_list_iam_ic_groups() { 
    local identity_store_id="$1"

    log_empty_line
    log_info "Listing IAM Identity Center groups in Identity Store $identity_store_id:"

    # --query 'Groups[].{GroupName:DisplayName, GroupId:GroupId}' \
    aws identitystore list-groups \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --identity-store-id "$identity_store_id" \
        --output table
}

list_iam_ic_groups() {
    local identity_store_id
    if ! identity_store_id=$(prompt_user_for_value "Identity Store ID"); then
        log_error "Identity Store ID is required!"
        return 1
    fi

    _list_iam_ic_groups "$identity_store_id"
}

identity_services_menu() {
    local menu_options=(
        "List IAM users"
        "List IAM roles"
        "List IAM policies"
        "List IAM groups"
        "List IAM users in a group"
        "List IAM roles in a group"
        "Show details of an IAM role"
        "Show details of an IAM user"
        "Lookup AssumeRoleWithWebIdentity events"
        "Watch for new AssumeRoleWithWebIdentity events"
        "List Identity Stores"
        "List IAM Identity Center users"
        "Show details of an IAM Identity Center user"
        "List IAM Identity Center groups"
        "EXIT"
    )

    while true; do
        log_empty_line
        log_info "IAM menu - choose an option:"
        select option in "${menu_options[@]}"; do
            if [[ -n "$option" ]]; then
                log_info "Selected option: $option\n"
                case $option in
                    "List IAM users")
                        list_iam_users
                        ;;
                    "List IAM roles")
                        list_iam_roles
                        ;;
                    "List IAM policies")
                        list_iam_policies
                        ;;
                    "List IAM groups")
                        list_iam_groups
                        ;;
                    "List IAM users in a group")
                        list_iam_users_in_group
                        ;;
                    "List IAM roles in a group")
                        list_iam_roles_in_group
                        ;;
                    "Show details of an IAM role")
                        show_iam_role_details
                        ;;
                    "Show details of an IAM user")
                        show_iam_user_details
                        ;;
                    "Lookup AssumeRoleWithWebIdentity events")
                        lookup_assume_role_events
                        ;;
                    "Watch for new AssumeRoleWithWebIdentity events")
                        watch_assume_role_events
                        ;;
                    "List Identity Stores")
                        list_identity_stores
                        ;;
                    "List IAM Identity Center users")
                        list_iam_ic_users
                        ;;
                    "Show details of an IAM Identity Center user")
                        show_details_of_iam_ic_user
                        ;;
                    "List IAM Identity Center groups")
                        list_iam_ic_groups
                        ;;
                    "EXIT")
                        log_info "Exiting IAM menu."
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
