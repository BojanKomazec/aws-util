#!/usr/bin/env bash

show_current_caller_iam_identity() {
    log_empty_line
    log_info "Current caller IAM identity details: "
    aws sts get-caller-identity --profile "${AWS_PROFILE:-default}"
}

# Check if AWS credentials are configured
# Use e.g. aws sso login --profile <profile>
check_aws_credentials() {
    log_empty_line
    local profile="${AWS_PROFILE:-default}"
    log_info "Verifying AWS credentials for profile: $profile"

    if ! aws sts get-caller-identity --profile "$profile" &> /dev/null; then
        log_error "AWS credentials not configured or invalid."
        return 1
    else
        log_success "AWS credentials are valid for profile: $profile"
        return 0
    fi
}

# Authenticates AWS CLI session using IAM Identity Center (formerly SSO) for a specific configured profile.
# It opens a browser to verify credentials and caches short-lived session tokens in ~/.aws/sso/cache, allowing you
# to run CLI commands (e.g., aws s3 ls --profile <profile_name>) without entering credentials repeatedly.
authenticate_aws_cli_using_sso() {
    local profile="$1"
    if [ -z "$profile" ]; then
        log_error "AWS profile is required for SSO authentication."
        return 1
    fi

    log_info "Authenticating AWS CLI using SSO for profile: $profile"
    if aws sso login --profile "$profile"; then
        log_success "Successfully authenticated AWS CLI using SSO for profile: $profile"
        return 0
    else
        log_error "Failed to authenticate AWS CLI using SSO for profile: $profile"
        return 1
    fi
}

sts() {
    show_current_caller_iam_identity
}