#!/usr/bin/env bash

source ./modules/ec2/ebs.sh

show_current_context(){
    log_empty_line
    log_info "Current kubectl context:"
    kubectl config current-context
}

list_all_contexts_names() {
    log_empty_line
    log_info "All kubectl contexts:"
    kubectl config get-contexts -o name
}

list_all_contexts_details() {
    log_empty_line
    log_info "All kubectl contexts:"
    kubectl config get-contexts
}

refresh_or_create_context() {
    local context_name="$1"
    local cluster_name="$2"
    local user_name="$3"

    # Check if the context already exists
    if kubectl config get-contexts "$context_name" > /dev/null 2>&1; then
        log_info "Context '$context_name' already exists. Refreshing it..."
        kubectl config delete-context "$context_name"
    else
        log_info "Context '$context_name' does not exist. Creating it..."
    fi

    # Create the new context
    kubectl config set-context "$context_name" --cluster="$cluster_name" --user="$user_name"

    # aws eks update-kubeconfig --region <region-code> --name <cluster-name>
}

list_ebs_volumes() {
    log_empty_line
    log_info "EBS Volumes for account $AWS_PROFILE in region $AWS_REGION:"

    printf "%-25s %-7s %-12s %-15s %-20s\n" "VOLUME-ID" "SIZE" "STATE" "K8S-NAMESPACE" "K8S-PVC-NAME"

    aws ec2 describe-volumes \
        --query 'Volumes[*].[VolumeId, Size, State]' \
        --output json \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        | jq -c '.[]' | while read -r vol; do
        V_ID=$(echo $vol | jq -r '.[0]')
        V_SIZE=$(echo $vol | jq -r '.[1]')
        V_STATE=$(echo $vol | jq -r '.[2]')

        # Check if this Volume ID exists as a PV in K8s
        K8S_INFO=$(kubectl get pv -o json | jq -r --arg vid "$V_ID" '.items[] | select(.spec.csi.volumeHandle == $vid) | [.spec.claimRef.namespace, .spec.claimRef.name] | @tsv' 2>/dev/null)

        if [ -z "$K8S_INFO" ]; then
            # Not found in K8s (it's orphaned or just Available)
            printf "%-25s %-7s %-12s %-15s %-20s\n" "$V_ID" "${V_SIZE}Gi" "$V_STATE" "---" "---"
        else
            # Found in K8s
            V_NS=$(echo "$K8S_INFO" | awk '{print $1}')
            V_PVC=$(echo "$K8S_INFO" | awk '{print $2}')
            printf "%-25s %-7s %-12s %-15s %-20s\n" "$V_ID" "${V_SIZE}Gi" "$V_STATE" "$V_NS" "$V_PVC"
        fi
    done
}

_list_ebs_volumes_in_use_in_k8s_cluster() {
    local min_size="$1" # in GiB
    output=$(kubectl get pv -o json | \
        jq -r --arg min_size "$min_size" '.items[] |
        select(.spec.capacity.storage | sub("Gi";"") | tonumber >= ($min_size | tonumber)) |
        [.spec.csi.volumeHandle, .spec.capacity.storage, .spec.claimRef.namespace, .spec.claimRef.name] |
        @tsv' | \
        column -t)
    echo "$output"
}

list_ebs_volumes_in_use_in_k8s_cluster() {
    log_empty_line

    min_size=${1:-0} # in GiB
    log_wait "Fetching EBS Volumes in use in K8s cluster with size >= ${min_size}Gi..."

    echo -e "VOLUME-ID\t\tSIZE\tNAMESPACE\tPVC-NAME"
    output=$(_list_ebs_volumes_in_use_in_k8s_cluster "$min_size")
    if [ -z "$output" ]; then
        log_info "No volumes found in use in K8s cluster with size >= ${min_size}Gi."
    else
        echo "$output"
    fi
}

create_snapshots_for_volumes_in_k8s_cluster() {
    log_empty_line
    min_size=${1:-11} # in GiB
    snapshot_tag_name="EKS-Upgrade-Backup"
    log_wait "Creating snapshots for EBS volumes in use in K8s cluster with size >= ${min_size}Gi..."
    volumes_info=$(_list_ebs_volumes_in_use_in_k8s_cluster "$min_size")
    echo "$volumes_info"
    log_empty_line

    user_confirmed=$(prompt_user_for_confirmation "❓ Do you want to proceed with creating snapshots for the above volumes?" "n")
    if [[ "$user_confirmed" == "true" ]]; then
        log_info "Proceeding with snapshot creation..."
    else
        log_warning "Snapshot creation cancelled by user.";
        return;
    fi

    # iterate over each line in the output, extract the volume ID, namespace and pvc name
    # and create a snapshot for each volume
    echo "$volumes_info" | while read -r line; do
        V_ID=$(echo "$line" | awk '{print $1}')
        V_SIZE=$(echo "$line" | awk '{print $2}')
        V_NS=$(echo "$line" | awk '{print $3}')
        V_PVC=$(echo "$line" | awk '{print $4}')
        description="Snapshot for volume $V_ID (size: $V_SIZE) used by PVC $V_PVC in namespace $V_NS"
        create_ebs_snapshot "$V_ID" "$description" "$snapshot_tag_name"
    done
}

list_efs_volumes_in_use_in_k8s_cluster() {
    log_empty_line
    log_wait "Fetching EFS Volumes in use in K8s cluster..."

    output=$(kubectl get pv -o json | \
        jq -r '.items[] |
        select(.spec.csi.driver == "efs.csi.aws.com") |
        [.spec.csi.volumeHandle, .spec.capacity.storage, .spec.claimRef.namespace, .spec.claimRef.name] |
        @tsv' | \
        column -t)
    if [ -z "$output" ]; then
        log_info "No EFS volumes found in use in K8s cluster."
    else
        echo -e "VOLUME-ID\t\tSIZE\tNAMESPACE\tPVC-NAME"
        echo "$output"
    fi
}

eks() {
    #
    # Context
    #
    # list_all_contexts_names
    # list_all_contexts_details
    show_current_context

    #
    # EBS
    #
    # list_ebs_volumes
    list_ebs_volumes_in_use_in_k8s_cluster
    # list_ebs_volumes_in_use_in_k8s_cluster 11
    # create_snapshots_for_volumes_in_k8s_cluster

    #
    # EFS
    #
    list_efs_volumes_in_use_in_k8s_cluster
}