#!/bin/bash
set -e
echo "Starting AKS and ARC Deployment..."

RESOURCE_GROUP="rg-github-runners"
CLUSTER_NAME="aks-packer-builders"
LOCATION="eastus"

echo "Creating Resource Group..."
# az group create --name $RESOURCE_GROUP --location $LOCATION

echo "Creating AKS Cluster..."
# az aks create \
#   --resource-group $RESOURCE_GROUP \
#   --name $CLUSTER_NAME \
#   --node-count 1 \
#   --enable-cluster-autoscaler \
#   --min-count 1 \
#   --max-count 5 \
#   --nodepool-name systempool \
#   --generate-ssh-keys

echo "Adding dedicated Packer Builder Node Pool..."
# az aks nodepool add \
#   --resource-group $RESOURCE_GROUP \
#   --cluster-name $CLUSTER_NAME \
#   --name packerpool \
#   --node-count 0 \
#   --enable-cluster-autoscaler \
#   --min-count 0 \
#   --max-count 50 \
#   --node-vm-size Standard_D8s_v5

echo "Getting AKS Credentials..."
# az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME

echo "Installing Cert-Manager..."
# helm repo add jetstack https://charts.jetstack.io
# helm repo update
# helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --version v1.14.4 --set installCRDs=true

echo "Installing Actions Runner Controller (ARC)..."
# helm repo add actions-runner-controller https://actions-runner-controller.github.io/actions-runner-controller
# helm upgrade --install --namespace actions-runner-system --create-namespace \
#   --wait actions-runner-controller actions-runner-controller/actions-runner-controller \
#   --set syncPeriod=1m

# Install ARC AutoScaling RunnerSet using declarative K8s values
# helm install arc-packer-runners \
#    --namespace arc-runners \
#    --create-namespace \
#    -f arc-runner-scale-set-values.yaml \
#    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
