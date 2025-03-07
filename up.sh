#!/bin/bash
set -o errexit

CLUSTER_NAME="$(jq -r '.cluster_name' config.json)"
HOST_REGISTRY_NAME="$(jq -r '.host_registry_name' config.json)"
HOST_REGISTRY_PORT="$(jq -r '.host_registry_port' config.json)"
REGISTRY_NAME="$(jq -r '.registry_name' config.json)"
REGISTRY_PORT="$(jq -r '.registry_port' config.json)"
OS="$(uname)"

printf '%s\n' "Target environment ${OS}"

function create_cluster_linux {
  # create a cluster with the local registry enabled in containerd

  printf '%s\n' "Create cluster (linux)"
  cat <<EOF | kind create cluster --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
# - role: worker
# - role: worker
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri"]
    [plugins."io.containerd.grpc.v1.cri".registry]
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${HOST_REGISTRY_PORT}"]
          endpoint = ["http://${HOST_REGISTRY_NAME}:${HOST_REGISTRY_PORT}"]
      [plugins."io.containerd.grpc.v1.cri".registry.configs]
        [plugins."io.containerd.grpc.v1.cri".registry.configs."172.18.255.1:5000".tls]
          insecure_skip_verify = true
        [plugins."io.containerd.grpc.v1.cri".registry.configs."172.18.255.2:5000".tls]
          insecure_skip_verify = true
        [plugins."io.containerd.grpc.v1.cri".registry.configs."172.18.255.3:5000".tls]
          insecure_skip_verify = true
EOF
}

function create_cluster_darwin {
  # create a cluster with the local registry enabled in containerd

  printf '%s\n' "Create cluster (darwin)"
  cat <<EOF | kind create cluster --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 443
    hostPort: 443
    listenAddress: "0.0.0.0"
    protocol: tcp
  - containerPort: 80
    hostPort: 80
    listenAddress: "0.0.0.0"
    protocol: TCP
# - role: worker
# - role: worker
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri"]
    [plugins."io.containerd.grpc.v1.cri".registry]
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${HOST_REGISTRY_PORT}"]
          endpoint = ["http://${HOST_REGISTRY_NAME}:${HOST_REGISTRY_PORT}"]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."smartcheck-registry.localdomain:443"]
          endpoint = ["https://${REGISTRY_NAME}:${REGISTRY_PORT}"]
EOF
}

function create_host_registry {
  # create registry container unless it already exists
  printf '%s\n' "Create host registry"

  running="$(docker inspect -f '{{.State.Running}}' "${HOST_REGISTRY_NAME}" 2>/dev/null || true)"
  if [ "${running}" != 'true' ]; then
    docker run \
      -d --restart=always -p "${HOST_REGISTRY_PORT}:5000" --name "${HOST_REGISTRY_NAME}" \
      registry:2 >/dev/null 2>&1
  fi
  printf '%s\n' "Host registry created 🍺"
}

function configure_host_registry {
  # connect the registry to the cluster network
  # (the network may already be connected)
  printf '%s\n' "Configure host registry"

  docker network connect "kind" "${HOST_REGISTRY_NAME}" || true

  # Document the local registry
  # https://github.com/kubernetes/enhancements/tree/master/keps/sig-cluster-lifecycle/ \
  # generic/1755-communicating-a-local-registry
  echo "---" >> up.log
  cat <<EOF | kubectl apply -f - -o yaml | cat >> up.log
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${HOST_REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
  printf '%s\n' "Host registry configured 🍷"
}

function create_load_balancer {
  # load balancer
  printf '%s' "Create load balancer"

  echo "---" >> up.log && \
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.9.5/manifests/namespace.yaml \
    -o yaml | cat >> up.log
  echo "---" >> up.log && \
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.9.5/manifests/metallb.yaml \
    -o yaml | cat >> up.log
  echo "---" >> up.log && \
    kubectl create secret generic -n metallb-system memberlist \
    --from-literal=secretkey="$(openssl rand -base64 128)" \
    -o yaml | cat >> up.log
  ADDRESS_POOL=$(kubectl get nodes -o json | \
    jq -r '.items[0].status.addresses[] | select(.type=="InternalIP") | .address' | \
    sed -r 's|([0-9]*).([0-9]*).*|\1.\2.255.1-\1.\2.255.250|')

  echo "---" >> up.log
  cat <<EOF | kubectl apply -f - -o yaml | cat >> up.log 
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - ${ADDRESS_POOL}
EOF
  printf '%s\n' "Load balancer created 🍹"
}

function create_ingress_controller {
  # ingress nginx
  # original manifest: 
  # https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/kind/deploy.yaml
  printf '%s\n' "Create ingress controller"
  kubectl apply -f ingress-nginx.yaml -o yaml | cat >> up.log

  # wating for the cluster be ready
  printf '%s' "Wating for the cluster be ready"

  while [ $(kubectl -n kube-system get deployments | \
          grep -cE "1/1|2/2|3/3|4/4|5/5") -ne $(kubectl -n kube-system get deployments | \
          grep -c "/") ]; do
    printf '%s' "."
    sleep 2
  done

  kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=90s \
    -o yaml | cat >> up2.log
    
  printf '\n%s\n' "Cluster and ingress controller ready 🍾"
}

# flush logfile
echo > up.log

create_host_registry

if [ "${OS}" == 'Linux' ]; then
  create_cluster_linux
fi
if [ "${OS}" == 'Darwin' ]; then
  create_cluster_darwin
fi

configure_host_registry
create_load_balancer
create_ingress_controller

./deploy-registry.sh
