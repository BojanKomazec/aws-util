#!/usr/bin/env bash
# shellcheck disable=SC1090

source ./util.sh

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
source ./modules/identity_services.sh
source ./modules/lambda.sh
source ./modules/networking.sh
source ./modules/sts.sh
source ./modules/vpc/vpc.sh

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

main_menu() {
    local menu_options=(
        "ebs"
        "cloudwatch_logs"
        "eks"
        "identity services"
        "lambda"
        "networking"
        "sts"
        "vpc"
        "EXIT"
    )

    while true; do
        show_menu_select_message "main menu"

        select option in "${menu_options[@]}"; do
            if [[ -n "$option" ]]; then
                log_info "Selected option: $option\n"
                case $option in
                    "ebs")
                        ebs_menu
                        ;;
                    "cloudwatch_logs")
                        cloudwatch_logs_menu
                        ;;
                    "eks")
                        eks_menu
                        ;;
                    "identity services")
                        identity_services_menu
                        ;;
                    "lambda")
                        lambda_menu
                        ;;
                    "networking")
                        networking_menu
                        ;;
                    "sts")
                        sts_menu
                        ;;
                    "vpc")
                        vpc_menu
                        ;;
                    "EXIT")
                        log_finish "Exiting..."
                        exit 0
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

main() {
    log_info "SCRIPT_DIR = $SCRIPT_DIR"
    load_env_file "$SCRIPT_DIR/.env"
    print_env_variables
    check_if_command_tool_is_available "aws" || exit 1
    check_aws_credentials || exit 1

    main_menu
}

main
