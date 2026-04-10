#!/usr/bin/env bash

source ./util.sh

# Example usage: create_ebs_snapshot "vol-0123456789abcdef0" "My snapshot description" "MySnapshotTag"
# Tag example: "EKS-Upgrade-Backup"
_create_ebs_snapshot() {
    local volume_id="$1"
    local description="$2"
    local tag_name="$3"
    local output
    local exit_code

    log_info "Creating snapshot for volume $volume_id with description '$description' and tag '$tag_name'..."
    
    output=$(aws ec2 create-snapshot \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" \
        --volume-id "$volume_id" \
        --description "$description" \
        --query 'SnapshotId' \
        --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$tag_name}]" \
        --output text 2>&1)
    exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        log_error "Failed to create snapshot for volume $volume_id: $output"
        return 1
    fi
    
    log_success "Created snapshot $output for volume $volume_id with description '$description'"
    return 0
}

create_ebs_snapshot() {
    local volume_id
    local description
    local tag_name

    if ! volume_id=$(prompt_user_for_value "Volume ID to snapshot (e.g., vol-0123456789abcdef0)"); then
        log_error "Volume ID is required. Aborting."
        return 1
    fi

    if ! description=$(prompt_user_for_value "Snapshot description"); then
        log_error "Snapshot description is required. Aborting."
        return 1
    fi

    if ! tag_name=$(prompt_user_for_value "Tag name for the snapshot (e.g., MySnapshotTag)"); then
        log_error "Tag name is required. Aborting."
        return 1
    fi

    _create_ebs_snapshot "$volume_id" "$description" "$tag_name"
}


describe_ebs_snapshot() {
    local snapshot_id="$1"
    local output
    local exit_code

    output=$(aws ec2 describe-snapshots \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" \
        --snapshot-ids "$snapshot_id" \
        --query "Snapshots[0].{Name:Tags[?Key==\`Name\`].Value | [0],SnapshotId:SnapshotId,VolumeId:VolumeId,State:State,StartTime:StartTime,Description:Description}" \
        --output json 2>&1)
    exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log_error "Failed to describe snapshot $snapshot_id: $output"
        return 1
    fi

    echo "$output" | jq
    return 0
}

describe_ebs_snapshots() {
    log_empty_line
    local output
    local exit_code

    log_wait "Fetching EBS snapshots for account $AWS_PROFILE in region $AWS_REGION..."

    # --output table | json
    output=$(aws ec2 describe-snapshots \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" \
        --owner-ids self \
        --query "Snapshots[*].{ \
            Name:Tags[?Key==\`Name\`].Value | [0], \
            SnapshotId:SnapshotId, \
            VolumeId:VolumeId, \
            State:State, \
            StartTime:StartTime, \
            Description:Description, \
            Progress:Progress \
        }" \
        --output json 2>&1)
    exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log_error "Failed to describe snapshots: $output"
        return 1
    fi

    if [ -z "$output" ]; then
        log_info "No snapshots found."
    else
        log_info "EBS Snapshots for account $AWS_PROFILE in region $AWS_REGION:"
        echo "$output"
    fi

    return 0
}

create_volume_from_snapshot() {
    local snapshot_id="$1"
    local availability_zone="$2"
    local output
    local exit_code

    output=$(aws ec2 create-volume \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" \
        --snapshot-id "$snapshot_id" \
        --availability-zone "$availability_zone" \
        --volume-type gp3 \
        --query 'VolumeId' \
        --output text 2>&1)
    exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log_error "Failed to create volume from snapshot $snapshot_id: $output"
        return 1
    fi

    log_success "Created volume $output from snapshot $snapshot_id in availability zone $availability_zone"
    return 0
}

delete_ebs_snapshot() {
    local snapshot_id="$1"
    local output
    local exit_code

    output=$(aws ec2 delete-snapshot \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" \
        --snapshot-id "$snapshot_id" 2>&1)
    exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log_error "Failed to delete snapshot $snapshot_id: $output"
        return 1
    fi

    log_success "Deleted snapshot $snapshot_id successfully"
    return 0
}

prompt_delete_ebs_snapshot() {
    local snapshot_id
    local output
    local exit_code

    if ! snapshot_id=$(prompt_user_for_value "Snapshot ID to delete"); then
        log_error "Failed to get snapshot ID. Aborting."
        return 1
    fi

    local user_confirmed
    user_confirmed=$(prompt_user_for_confirmation "❓ Are you sure you want to delete snapshot '$snapshot_id'?" "n")
    if [[ "$user_confirmed" == "true" ]]; then
        delete_ebs_snapshot "$snapshot_id"
    else
        log_warning "Skipping deletion of snapshot: $snapshot_id"
    fi
    return 0
}

delete_ebs_snapshots_by_tag() {
    local tag_key="$1"
    local tag_value="$2"
    local output
    local exit_code

    output=$(aws ec2 describe-snapshots \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" \
        --owner-ids self \
        --filters "Name=tag:$tag_key,Values=$tag_value" \
        --query "Snapshots[].SnapshotId" \
        --output text 2>&1)
    exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log_error "Failed to describe snapshots with tag $tag_key=$tag_value: $output"
        return 1
    fi

    if [ -z "$output" ]; then
        log_info "No snapshots found with tag $tag_key=$tag_value."
        return 0
    fi

    log_info "Found snapshots with tag $tag_key=$tag_value: $output"

    for snapshot_id in $output; do
        # Prompt for confirmation before deleting each snapshot
        local user_confirmed
        user_confirmed=$(prompt_user_for_confirmation "❓ Are you sure you want to delete snapshot '$snapshot_id' with tag $tag_key=$tag_value?" "n")
        if [[ "$user_confirmed" != "true" ]]; then
            log_warning "Skipping deletion of snapshot: $snapshot_id"
            continue
        fi
        delete_ebs_snapshot "$snapshot_id"
    done

    return 0
}

prompt_delete_ebs_snapshots_by_tag() {
    local tag_key
    local tag_value

    if ! tag_key=$(prompt_user_for_value "Tag key to filter snapshots for deletion"); then
        log_error "Failed to get tag key. Aborting."
        return 1
    fi

    if ! tag_value=$(prompt_user_for_value "Tag value to filter snapshots for deletion"); then
        log_error "Failed to get tag value. Aborting."
        return 1
    fi

    delete_ebs_snapshots_by_tag "$tag_key" "$tag_value"
}

ebs_menu() {
    local menu_options=(
        "Describe EBS snapshots"
        "Create snapshot from volume"
        "Create volume from snapshot"
        "Delete EBS snapshot"
        "Delete EBS snapshots by tag"
        "EXIT"
    )

    while true; do
        show_menu_select_message "EBS"
        select option in "${menu_options[@]}"; do
            if [[ -n "$option" ]]; then
                log_info "Selected option: $option\n"
                case $option in
                    "Describe EBS snapshots")
                        describe_ebs_snapshots
                        ;;
                    "Create snapshot from volume")
                        create_ebs_snapshot
                        ;;
                    "Create volume from snapshot")
                        prompt_create_volume_from_snapshot
                        ;;
                    "Delete EBS snapshot")
                        prompt_delete_ebs_snapshot
                        ;;
                    "Delete EBS snapshots by tag")
                        prompt_delete_ebs_snapshots_by_tag
                        ;;
                    "EXIT")
                        log_info "Exiting EBS menu."
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
