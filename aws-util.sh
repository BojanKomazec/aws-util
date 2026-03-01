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

source ./modules/cloudwatch_logs.sh
source ./modules/ec2/ebs.sh
source ./modules/eks.sh
source ./modules/lambda.sh
source ./modules/networking.sh
source ./modules/sts.sh

# required by imported log.sh
VERBOSE=true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_env_variables() {
    log_empty_line
    log_info "Environment variables:"
    log_info "AWS_PROFILE=$AWS_PROFILE"
    log_info "AWS_REGION=$AWS_REGION"
    log_info "SG_ID=$SG_ID"
    log_info "OLD_FILTER_DESTINATION_ARN=$OLD_FILTER_DESTINATION_ARN"
    log_info "NEW_FILTER_NAME=$NEW_FILTER_NAME"
    log_info "NEW_FILTER_DESTINATION_ARN=$NEW_FILTER_DESTINATION_ARN"
    log_info "AWS_CLOUDWATCH_TO_KINESIS_ROLE_ARN=$AWS_CLOUDWATCH_TO_KINESIS_ROLE_ARN"
    log_info "AWS_PAGER=$AWS_PAGER"
}

main() {
    log_info "SCRIPT_DIR = $SCRIPT_DIR"
    load_env_file "$SCRIPT_DIR/.env"
    print_env_variables
    check_if_command_tool_is_available "aws" || exit 1
    check_aws_credentials || exit 1

    # sts
    eks
    # ec2
    # describe_ebs_snapshots
}

main
