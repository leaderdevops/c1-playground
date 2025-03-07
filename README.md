# Playground

- [Playground](#playground)
  - [Requirements](#requirements)
  - [Configure](#configure)
  - [Start Linux](#start-linux)
  - [Start MacOS (in progress)](#start-macos-in-progress)
  - [Tear Down](#tear-down)
  - [Tests](#tests)
    - [Registry](#registry)
    - [Host Registry](#host-registry)
    - [Container Security](#container-security)
    - [Smart Check](#smart-check)

Ultra fast and slim kubernetes playground

## Requirements

*Tested on Ubuntu Bionic only, MacOS 10+ in progress*

Install required packages if not available. **After the installation continue in a new shell.**

```sh
# install packages
sudo apt update
sudo apt install -y jq apt-transport-https gnupg2 curl nginx

# install docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
ME=$(whoami)
sudo usermod -aG docker ${ME}

# kubectl
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee -a /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubectl

# helm
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh

# kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.9.0/kind-linux-amd64
chmod +x ./kind
sudo mv kind /usr/local/bin/
```

**IMPORTANT: Proceed in a new shell!**

## Configure

After cloning the repo to your machine create your personal configuration file.

```sh
git clone https://github.com/mawinkler/c1-playground.git
cd c1-playground
cp config.json.sample config.json
```

Typically you don't need to change anything here besides setting your api key for C1 and an activation key for smart check.

```json
{
    ...
    "api_key": "YOUR KEY HERE",
    "activation_key": "YOUR KEY HERE"
}
```

At this point we need to determine the network that is being used for the node ip pool. For that, we need to run `up.sh` and then query the nodes.

```sh
kubectl get nodes -o json | jq -r '.items[0].status.addresses[] | select(.type=="InternalIP") | .address'
```

```sh
172.18.0.2
```

The `up.sh` script will deploy a load balancer amongst others. It will get a range of ip addresses assigned to distribute them to service clients. The defined range is `X.X.255.1-X.X.255.250`. If the registry is deployed it will very likely be the second service requesting a load balancer IP, so typically it will get the `172.18.255.2` assignend which we define as an insecure registry for our local docker daemon.

To do this, create or modify `/etc/docker/daemon.json` to include a small subset probable ips for the registry.

```json
{"insecure-registries": ["172.18.255.1:5000","172.18.255.2:5000","172.18.255.3:5000"]}
```

Finally restart the docker daemon.

```sh
./stop.sh
sudo systemctl restart docker
```

## Start Linux

```sh
./up.sh
./deploy-smartcheck.sh
./deploy-proxy.sh
```

If you want to deploy Container Security, run

```sh
./deploy-container-security.sh
```

## Start MacOS (in progress)

Support for MacOS is still in progress.

```sh
./up.sh
./deploy-registry.sh
./deploy-smartcheck.sh
```

```sh
kubectl port-forward -n smartcheck svc/proxy 1443:443
```

Access Smart Check with browser `https://localhost:1443`

## Tear Down

```sh
./down.sh
```

## Tests

### Registry

```sh
# pull hello-app:1.0 from Google and push it to the cluster registry
# verify w/ curl
REGISTRY_NAME="$(jq -r '.registry_name' config.json)"
REGISTRY_NAMESPACE="$(jq -r '.registry_namespace' config.json)"
REGISTRY_USERNAME="$(jq -r '.registry_username' config.json)"
REGISTRY_PASSWORD="$(jq -r '.registry_password' config.json)"
REGISTRY_PORT="$(jq -r '.registry_port' config.json)"
REGISTRY_IP=$(kubectl get svc -n ${REGISTRY_NAMESPACE} ${REGISTRY_NAME} \
              -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo ${REGISTRY_PASSWORD} | docker login https://${REGISTRY_IP}:${REGISTRY_PORT} --username ${REGISTRY_USERNAME} --password-stdin

docker pull gcr.io/google-samples/hello-app:1.0
docker tag gcr.io/google-samples/hello-app:1.0 ${REGISTRY_IP}:${REGISTRY_PORT}/hello-app:1.0
docker push ${REGISTRY_IP}:${REGISTRY_PORT}/hello-app:1.0
curl -k https://${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}@${REGISTRY_IP}:${REGISTRY_PORT}/v2/_catalog
```

```sh
# create a pull secret and deployment
kubectl create secret docker-registry regcred --docker-server=${REGISTRY_IP}:${REGISTRY_PORT} --docker-username=${REGISTRY_USERNAME} --docker-password=${REGISTRY_PASSWORD} --docker-email=info@mail.com

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  annotations:
    service.alpha.kubernetes.io/tolerate-unready-endpoints: "true"
  name: hello-server
  labels:
    app: hello-server
spec:
  type: LoadBalancer
  ports:
  - port: 8080
    name: hello-server
    targetPort: 8080
  selector:
    app: hello-server
---
apiVersion: apps/v1
kind: Deployment
metadata:
  creationTimestamp: null
  labels:
    app: hello-server
  name: hello-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hello-server
  strategy: {}
  template:
    metadata:
      creationTimestamp: null
      labels:
        app: hello-server
    spec:
      containers:
      - image: ${REGISTRY_IP}:${REGISTRY_PORT}/hello-app:1.0
        name: hello-app
        ports:
        - containerPort: 8080
      imagePullSecrets:
      - name: regcred
EOF

echo Try: curl $(kubectl --namespace default get svc hello-server \
              -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):8080
```

Echo Server

```sh
# instant deployment and scale an echo-server
kubectl create deployment echo --image=inanimate/echo-server
kubectl scale deployment echo --replicas=3
kubectl get deployments
kubectl expose deployment echo --port=8080 --type LoadBalancer

echo Try: curl $(kubectl --namespace default get svc echo \
              -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):8080
```

### Host Registry

```sh
# test the shared registry running on the host
# pull hello-app:2.0 from Google and push it to the host registry
# deploy to the cluster
docker pull gcr.io/google-samples/hello-app:2.0
docker tag gcr.io/google-samples/hello-app:2.0 localhost:5000/hello-app:2.0
docker push localhost:5000/hello-app:2.0
kubectl create deployment hello-server-2 --image=localhost:5000/hello-app:2.0

echo Try: kubectl get pods | grep hello-server-2
```

### Container Security

```sh
# try to deploy nginx pod in its own namspace - fail if you set the policy to block
kubectl create namespace nginx --dry-run=client -o yaml | kubectl apply -f - > /dev/null
kubectl create deployment --image=nginx --namespace nginx nginx
```

### Smart Check

Ensure to have `deploy-smartcheck.sh` run.

Do trigger a scan of an image

```sh
TARGET_IMAGE=busybox
TARGET_IMAGE_TAG=latest

./scan-image.sh
```

If you want to trigger a build time scan run

```sh
TARGET_IMAGE=busybox
TARGET_IMAGE_TAG=latest

./scan-image-buildtime.sh
```

To access the UI of Smart Check run `deploy-proxy.sh`. Point your broswer to the ip address of the host with the configured port.
