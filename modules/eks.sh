#!/usr/bin/env bash

kubernetes_versions() {
    log_empty_line
    log_info "Kubectl version:"
    kubectl version
}

# Get Kubernetes version of the current cluster but only the version number, e.g. 1.27
# kubectl version returns e.g. Server Version: v1.32.11-eks-ac2d5a0 and we want to return only 1.32
get_cluster_version() {
    log_empty_line
    log_info "Getting Kubernetes version of the current cluster:"
    output=$(kubectl version | grep "Server Version" | awk '{print $3}' | sed 's/^v//;s/-.*//;s/\([0-9]*\.[0-9]*\).*/\1/')
    echo "$output"
}

list_clusters() {
    log_empty_line
    log_info "Listing EKS clusters in region $AWS_REGION for account $AWS_PROFILE:"

    output=$(aws eks list-clusters \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" \
        --query 'clusters' \
        --output json 2>&1)

    echo "$output" | jq
}

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

get_cluster_name_from_current_context() {
    local current_context
    current_context=$(kubectl config current-context)
    # EKS context format is usually: arn:aws:eks:<region>:<account-id>:cluster/<cluster-name>
    local cluster_name
    cluster_name=$(echo "$current_context" | awk -F'/' '{print $NF}')
    echo "$cluster_name"
}

show_cluster_status() {
    local cluster_name="$1"

    log_empty_line
    log_info "Showing status of EKS cluster '$cluster_name' in region $AWS_REGION for account $AWS_PROFILE:"

    output=$(aws eks describe-cluster \
        --name "$cluster_name" \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" \
        --query 'cluster.{Name:name,Status:status,Version:version,PlatformVersion:platformVersion,Endpoint:endpoint,ARN:arn}' \
        --output json 2>&1)

    echo "$output" | jq
}

show_update_status_of_cluster() {
    local cluster_name="$1"
    local update_id

    log_empty_line
    log_info "Fetching the most recent update ID for EKS cluster '$cluster_name' in region $AWS_REGION for account $AWS_PROFILE..."

    update_id=$(aws eks list-updates \
        --name "$cluster_name" \
        --query 'updateIds[0]' \
        --output text \
        --profile "$AWS_PROFILE")

    log_info "Most recent update ID: $update_id"

    log_empty_line
    log_info "Showing update $update_id status of EKS cluster '$cluster_name' in region $AWS_REGION for account $AWS_PROFILE:"

    output=$(aws eks describe-update \
        --name "$cluster_name" \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" \
        --update-id "$update_id" \
        --query 'update.{Id:updateId,Status:status,Type:type,StartTime:createdAt}' \
        --output json 2>&1)

    echo "$output" | jq
}

wait_for_cluster_update_to_complete() {
    local cluster_name="$1"
    local update_id="$2"

    log_info "Waiting for update $update_id of EKS cluster '$cluster_name' to complete..."

    while true; do
        output=$(aws eks describe-update \
            --name "$cluster_name" \
            --region "$AWS_REGION" \
            --profile "$AWS_PROFILE" \
            --update-id "$update_id" \
            --query 'update.status' \
            --output text 2>&1)

        if [ "$output" == "Failed" ]; then
            log_error "Cluster update $update_id failed."
            return 1
        elif [ "$output" == "Successful" ]; then
            log_success "Cluster update $update_id completed successfully."
            return 0
        else
            log_info "Cluster update $update_id is still in progress. Current status: $output. Checking again in 30 seconds..."
            sleep 30
        fi
    done
}

# Wait until JMESPath query cluster.status returns ACTIVE when polling with describe-cluster. It will poll every 30 seconds until a successful state has been reached. This will exit with a return code of 255 after 40 failed checks.
wait_for_cluster_to_be_active() {
    local cluster_name="$1"

    log_info "Waiting for EKS cluster '$cluster_name' to be in ACTIVE state..."
    echo "Waiting for cluster to reach status ACTIVE..."
    if ! aws eks wait cluster-active \
        --name "$cluster_name" \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE";
    then
        log_error "Failed to wait for cluster to be active. Error code: $?"
    else
        log_success "Upgrade Complete!"
    fi
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

_list_addons() {
    eks_cluster_name=$1
    aws_region=$2
    aws_profile=$3

    output=$(aws eks list-addons \
        --cluster-name "$eks_cluster_name" \
        --region "$aws_region" \
        --profile "$aws_profile" \
        --query 'addons' \
        --output json 2>&1)
    echo "$output"
}

list_addons() {
    log_empty_line

    EKS_CLUSTER_NAME=$(kubectl config current-context | cut -d'/' -f2)
    log_info "Listing EKS addons for cluster $EKS_CLUSTER_NAME in region $AWS_REGION:"

    output=$(_list_addons "$EKS_CLUSTER_NAME" "$AWS_REGION" "$AWS_PROFILE")
    echo "$output" | jq
}

show_addons_details() {
    log_empty_line

    EKS_CLUSTER_NAME=$(kubectl config current-context | cut -d'/' -f2)
    log_info "Showing details of EKS addons for cluster $EKS_CLUSTER_NAME in region $AWS_REGION:"

    addons_names=$(_list_addons "$EKS_CLUSTER_NAME" "$AWS_REGION" "$AWS_PROFILE" | jq -r '.[]')
    for addon in $addons_names; do
        log_info "Addon: $addon"
        output=$(aws eks describe-addon \
            --cluster-name "$EKS_CLUSTER_NAME" \
            --addon-name "$addon" \
            --region "$AWS_REGION" \
            --profile "$AWS_PROFILE" \
            --output json 2>&1)
        echo "$output" | jq

        log_empty_line
        local cluster_version
        cluster_version=$(get_cluster_version)
        log_info "Checking latest available version of addon $addon for Kubernetes version $cluster_version..."
        output=$(aws eks describe-addon-versions \
            --addon-name "$addon" \
            --kubernetes-version "$cluster_version" \
            --region "$AWS_REGION" \
            --profile "$AWS_PROFILE" \
            --output json 2>&1)

        # show only the latest version of the addon
        latest_version=$(echo "$output" | jq -r '.addons[0].addonVersions | sort_by(.addonVersion) | last | .addonVersion')
        log_info "Latest available version of addon $addon: $latest_version"
        log_empty_line
    done
}

eks() {
    local cluster_name

    kubernetes_versions
    get_cluster_version

    #
    # Clusters
    #
    list_clusters

    #
    # Context
    #
    # list_all_contexts_names
    # list_all_contexts_details
    show_current_context

    cluster_name=$(get_cluster_name_from_current_context)
    log_info "Cluster name extracted from current context: $cluster_name"

    show_cluster_status "$cluster_name"
    show_update_status_of_cluster "$cluster_name"
    wait_for_cluster_to_be_active "$cluster_name"

    #
    # Addons
    #
    # list_addons
    # show_addons_details

    #
    # EBS
    #
    # list_ebs_volumes
    # list_ebs_volumes_in_use_in_k8s_cluster
    # list_ebs_volumes_in_use_in_k8s_cluster 11
    # create_snapshots_for_volumes_in_k8s_cluster

    #
    # EFS
    #
    # list_efs_volumes_in_use_in_k8s_cluster
}