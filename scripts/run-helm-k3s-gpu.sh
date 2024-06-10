#!/bin/bash
cd /home/spheron

export KUBECONFIG=/home/spheron/.kube/kubeconfig
# Specify the absolute path of the variables file
variables="/home/spheron/variables"

# Source the variables file if it exists
[ -e "$variables" ] && . "$variables"

git clone  https://github.com/spheronFdn/provider-helm-charts.git
cd provider-helm-charts/charts
git checkout devnet-spheron

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add rook-release https://charts.rook.io/release
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia

helm repo update

helm repo add nvdp https://nvidia.github.io/k8s-device-plugin

helm repo update

# Create NVIDIA RuntimeClass
cat > /home/spheron/gpu-nvidia-runtime-class.yaml <<EOF
kind: RuntimeClass
apiVersion: node.k8s.io/v1
metadata:
  name: nvidia
handler: nvidia
EOF

kubectl apply -f /home/spheron/gpu-nvidia-runtime-class.yaml

helm upgrade -i nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin \
  --create-namespace \
  --version 0.14.5 \
  --set runtimeClassName="nvidia" \
  --set deviceListStrategy=volume-mounts

# create containerd config
cat > etc/rancher/k3/config.yaml <<'EOF'
containerd_additional_runtimes:
 - name: nvidia
   type: "io.containerd.runc.v2"
   engine: ""
   root: ""
   options:
     BinaryName: '/usr/bin/nvidia-container-runtime'
EOF

setup_environment() {
    # Kubernetes config
    kubectl create ns akash-services
    kubectl label ns akash-services akash.network/name=akash-services akash.network=true
    kubectl create ns lease
    kubectl label ns lease akash.network=true
    kubectl apply -f https://raw.githubusercontent.com/akash-network/provider/main/pkg/apis/akash.network/crd.yaml
}


ingress_charts() {
    cat > ingress-nginx-custom.yaml << EOF
controller:
  service:
    type: ClusterIP
  ingressClassResource:
    name: "akash-ingress-class"
  kind: DaemonSet
  hostPort:
    enabled: true
  admissionWebhooks:
    port: 7443
  config:
    allow-snippet-annotations: false
    compute-full-forwarded-for: true
    proxy-buffer-size: "16k"
  metrics:
    enabled: true
  extraArgs:
    enable-ssl-passthrough: true
tcp:
  "1317": "akash-services/akash-node-1:1317"
  "8443": "akash-services/akash-provider:8443"
  "9090":  "akash-services/akash-node-1:9090"
  "26656": "akash-services/akash-node-1:26656"
  "26657": "akash-services/akash-node-1:26657"
EOF
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
      --namespace ingress-nginx --create-namespace \
      -f ingress-nginx-custom.yaml

kubectl label ns ingress-nginx app.kubernetes.io/name=ingress-nginx app.kubernetes.io/instance=ingress-nginx
kubectl label ingressclass akash-ingress-class akash.network=true

}


provider_setup() {
# Run nvidia-smi command to get GPU information
gpu_info="$(nvidia-smi --query-gpu=gpu_name --format=csv,noheader)"
gpu_models=$(echo "$gpu_info" |  awk '{print $2}')

echo "following gpu model found $gpu_models"
# Label nodes with specific GPU models using kubectl

node_name=$(hostname)
label_prefix="akash.network/capabilities.gpu.vendor.nvidia.model."

counter=1
for model in $gpu_models; do
    label_command="kubectl label node $node_name $label_prefix$model=true"
    $label_command
    
    # Construct the variable entry
    entry="GPU_$counter=$model"
    
    # Check if the entry already exists in the variables file
    if ! grep -q -e "^$entry$" $variables; then
        # If the entry does not exist, append it to the file
        echo "$entry" >> $variables
    fi
    
    ((counter++))
done

    helm upgrade --install akash-provider ./akash-provider -n akash-services \
        --set from=$ACCOUNT_ADDRESS \
        --set keysecret=$KEY_SECRET \
        --set domain=$DOMAIN \
        --set bidpricestrategy=randomRange \
        --set ipoperator=false \
        --set node=$NODE \
        --set log_restart_patterns="rpc node is not catching up|bid failed" \
        --set resources.limits.cpu="2" \
        --set resources.limits.memory="2Gi" \
        --set resources.requests.cpu="1" \
        --set resources.requests.memory="1Gi"

    kubectl patch configmap akash-provider-scripts \
      --namespace akash-services \
      --type json \
      --patch='[{"op": "add", "path": "/data/liveness_checks.sh", "value":"#!/bin/bash\necho \"Liveness check bypassed\""}]'

    kubectl rollout restart statefulset/akash-provider -n akash-services
    # Provider customizations
    # kubectl set env statefulset/akash-provider AKASH_GAS_PRICES=0.028uakt AKASH_GAS_ADJUSTMENT=1.42 AKASH_GAS=auto AKASH_BROADCAST_MODE=block AKASH_TX_BROADCAST_TIMEOUT=15m0s AKASH_BID_TIMEOUT=15m0s AKASH_LEASE_FUNDS_MONITOR_INTERVAL=90s AKASH_WITHDRAWAL_PERIOD=6h -n akash-services
}

hostname_operator() {
    helm upgrade --install akash-hostname-operator ./akash-hostname-operator -n akash-services
}

inventory_operator() {
    helm upgrade --install inventory-operator ./akash-inventory-operator -n akash-services
}

persistent_storage() {
echo "Persistent storage - MUST INSTALL apt-get install -y lvm2 on EACH NODDE BEFORE RUNNING"
    cat > rook.yml << EOF
operatorNamespace: rook-ceph

configOverride: |
  [global]
  osd_pool_default_pg_autoscale_mode = on
  osd_pool_default_size = 1
  osd_pool_default_min_size = 1

cephClusterSpec:
  resources:

  mon:
    count: 1
  mgr:
    count: 1

  storage:
    useAllNodes: true
    useAllDevices: true
    config:
      osdsPerDevice: "1"

cephBlockPools:
  - name: akash-deployments
    spec:
      failureDomain: host
      replicated:
        size: 1
      parameters:
        min_size: "1"
        deviceFilter: "^vd[a-z]$"
    storageClass:
      enabled: true
      name: beta1
      isDefault: false
      reclaimPolicy: Delete
      allowVolumeExpansion: true
      parameters:
        imageFormat: "2"
        imageFeatures: layering
        csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
        csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
        csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
        csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
        csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
        csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
        csi.storage.k8s.io/fstype: ext4

  - name: akash-deployments
    spec:
      failureDomain: host
      replicated:
        size: 1
      parameters:
        min_size: "1"
        deviceFilter: "^sd[a-z]$"
    storageClass:
      enabled: true
      name: beta2
      isDefault: false
      reclaimPolicy: Delete
      allowVolumeExpansion: true
      parameters:
        imageFormat: "2"
        imageFeatures: layering
        csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
        csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
        csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
        csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
        csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
        csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
        csi.storage.k8s.io/fstype: ext4

  - name: akash-deployments
    spec:
      failureDomain: host
      replicated:
        size: 1
      parameters:
        min_size: "1"
        deviceFilter: "^nvme[0-9]$"
    storageClass:
      enabled: true
      name: beta3
      isDefault: false
      reclaimPolicy: Delete
      allowVolumeExpansion: true
      parameters:
        imageFormat: "2"
        imageFeatures: layering
        csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
        csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
        csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
        csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
        csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
        csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
        csi.storage.k8s.io/fstype: ext4

  - name: akash-nodes
    spec:
      failureDomain: host
      replicated:
        size: 1
      parameters:
        min_size: "1"
    storageClass:
      enabled: true
      name: akash-nodes
      isDefault: false
      reclaimPolicy: Delete
      allowVolumeExpansion: true
      parameters:
        # RBD image format. Defaults to "2".
        imageFormat: "2"
        # RBD image features. Available for imageFormat: "2". CSI RBD currently supports only `layering` feature.
        imageFeatures: layering
        # The secrets contain Ceph admin credentials.
        csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
        csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
        csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
        csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
        csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
        csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
        # Specify the filesystem type of the volume. If not specified, csi-provisioner
        # will set default as `ext4`. Note that `xfs` is not recommended due to potential deadlock
        # in hyperconverged settings where the volume is mounted on the same node as the osds.
        csi.storage.k8s.io/fstype: ext4

# Do not create default Ceph file systems, object stores
cephFileSystems:
cephObjectStores:

# Spawn rook-ceph-tools, useful for troubleshooting
toolbox:
  enabled: true
  resources:
EOF

helm search repo rook-release --version v1.12.4
helm upgrade --install --wait --create-namespace -n rook-ceph rook-ceph rook-release/rook-ceph --version 1.12.4
echo "Did you update nodes in rook-ceph-cluster.values1.yml?"
#SHOWS DUPLICATE ISSUE - WORKS WHEN RUN TWICE
helm upgrade --install --create-namespace -n rook-ceph rook-ceph-cluster --set operatorNamespace=rook-ceph rook-release/rook-ceph-cluster --version 1.12.4 -f rook.yml --force

sleep 30

kubectl label sc akash-nodes akash.network=true
kubectl label sc beta3 akash.network=true
kubectl label sc beta2 akash.network=true
kubectl label sc beta1 akash.network=true

echo "Did you update this label to the same node in rook-ceph-cluster.values1.yml?"
kubectl label node $PERSISTENT_STORAGE_NODE1 akash.network/storageclasses=${PERSISTENT_STORAGE_NODE1_CLASS} --overwrite
kubectl label node $PERSISTENT_STORAGE_NODE2 akash.network/storageclasses=${PERSISTENT_STORAGE_NODE3_CLASS} --overwrite
kubectl label node $PERSISTENT_STORAGE_NODE3 akash.network/storageclasses=${PERSISTENT_STORAGE_NODE3_CLASS} --overwrite

echo "If health not OK, do this"
kubectl -n rook-ceph exec -it $(kubectl -n rook-ceph get pod -l "app=rook-ceph-tools" -o jsonpath='{.items[0].metadata.name}') -- bash -c "ceph health mute POOL_NO_REDUNDANCY"
}

run_functions() {
    for func in "$@"; do
        if declare -f "$func" > /dev/null; then
            echo "Running $func"
            "$func"
        else
            echo "Error: $func is not a known function"
            exit 1
        fi
    done
}

if [ "$#" -eq 0 ]; then
    run_functions setup_environment ingress_charts provider_setup hostname_operator inventory_operator
else
    run_functions "$@"
fi