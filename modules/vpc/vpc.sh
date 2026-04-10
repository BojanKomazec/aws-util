#!/usr/bin/env bash

source ./util.sh


get_vpcs() {
    log_empty_line
    log_info "Listing VPCs in region $AWS_REGION:"
    aws ec2 describe-vpcs \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --query "Vpcs[].{ID:VpcId,CIDR:CidrBlock,State:State,IsDefault:IsDefault}" \
        --output table
}

show_vpc_details() {
    local vpc_id

    log_empty_line
    if ! vpc_id=$(prompt_user_for_value "VPC ID to describe"); then
        log_error "VPC ID is required!"
        return 1
    fi

    log_info "Describing VPC: $vpc_id"
    aws ec2 describe-vpcs \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --vpc-ids "$vpc_id" \
        --output json | jq .
}

list_subnets_in_vpc() {
    local vpc_id

    log_empty_line
    if ! vpc_id=$(prompt_user_for_value "VPC ID to list subnets"); then
        log_error "VPC ID is required!"
        return 1
    fi

    log_info "Listing subnets in VPC: $vpc_id"
    aws ec2 describe-subnets \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --output json | jq .
}

list_route_tables_in_vpc() {
    local vpc_id

    log_empty_line
    if ! vpc_id=$(prompt_user_for_value "VPC ID to list route tables"); then
        log_error "VPC ID is required!"
        return 1
    fi

    log_info "Listing route tables in VPC: $vpc_id"
    aws ec2 describe-route-tables \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --output json | jq .
}

list_security_groups_in_vpc() {
    local vpc_id

    log_empty_line
    if ! vpc_id=$(prompt_user_for_value "VPC ID to list security groups"); then
        log_error "VPC ID is required!"
        return 1
    fi

    log_info "Listing security groups in VPC: $vpc_id"
    aws ec2 describe-security-groups \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --output json | jq .
}

list_network_acls_in_vpc() {
    local vpc_id

    log_empty_line
    if ! vpc_id=$(prompt_user_for_value "VPC ID to list network ACLs"); then
        log_error "VPC ID is required!"
        return 1
    fi

    log_info "Listing network ACLs in VPC: $vpc_id"
    aws ec2 describe-network-acls \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --output json | jq .
}

vpc_menu() {
    local options=(
        "List VPCs"
        "Show details of a specific VPC"
        "List subnets in a VPC"
        "List route tables in a VPC"
        "List security groups in a VPC"
        "List network ACLs in a VPC"
        "Back to main menu"
    )

    while true; do
        log_empty_line
        log_info "VPC Management Menu:"
        select opt in "${options[@]}"; do
            case $opt in
                "List VPCs")
                    get_vpcs
                    break
                    ;;
                "Show details of a specific VPC")
                    show_vpc_details
                    break
                    ;;
                "List subnets in a VPC")
                    list_subnets_in_vpc
                    break
                    ;;
                "List route tables in a VPC")
                    list_route_tables_in_vpc
                    break
                    ;;
                "List security groups in a VPC")
                    list_security_groups_in_vpc
                    break
                    ;;
                "List network ACLs in a VPC")
                    list_network_acls_in_vpc
                    break
                    ;;
                "Back to main menu")
                    return 0
                    ;;
                *)
                    log_error "Invalid option. Please try again."
                    ;;
            esac
        done
    done
}
