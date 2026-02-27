#!/usr/bin/env bash

 # Example usage: create_ebs_snapshot "vol-0123456789abcdef0" "My snapshot description" "MySnapshotTag"
create_ebs_snapshot() {
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

describe_ebs_snapshot() {
    local snapshot_id="$1"
    local output
    local exit_code

    output=$(aws ec2 describe-snapshots \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" \
        --snapshot-ids "$snapshot_id" \
        --query 'Snapshots[0].{SnapshotId:SnapshotId,VolumeId:VolumeId,State:State,StartTime:StartTime,Description:Description}' \
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
        --query 'Snapshots[*].{SnapshotId:SnapshotId,VolumeId:VolumeId,State:State,StartTime:StartTime,Description:Description,Progress:Progress}' \
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

ec2_ebs() {
    # create_ebs_snapshot "vol-0123456789abcdef0" "My snapshot description" "MySnapshotTag"

    describe_ebs_snapshots
}