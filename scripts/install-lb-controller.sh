#!/usr/bin/env bash
set -euo pipefail

#
# install-lb-controller.sh — Install the AWS Load Balancer Controller on EKS (PETPLAT-29)
#
# Applies the CRDs, adds the eks Helm repo, and installs the chart with the
# IRSA role created by the Terraform dns module.
#
# Usage:
#   ./scripts/install-lb-controller.sh dev
#   ./scripts/install-lb-controller.sh prod
#
# Prerequisites: terraform applied for the env, kubectl pointed at the cluster, helm installed.
#

REGION="us-east-1"
CHART_VERSION="3.6.1"   # controller v3.6.1; matches terraform/modules/dns/lb-controller-iam-policy.json
NAMESPACE="kube-system"
SERVICE_ACCOUNT="aws-load-balancer-controller"

usage() {
  echo "Usage: $0 <environment>"
  echo "  environment: dev | prod"
  exit 1
}

if [[ $# -ne 1 ]] || [[ "$1" != "dev" && "$1" != "prod" ]]; then
  usage
fi

ENV="$1"
TF_DIR="$(cd "$(dirname "$0")/.." && pwd)/terraform/environments/${ENV}"

for cmd in terraform kubectl helm; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd not found in PATH" >&2; exit 1; }
done

# Refuse to write to a cluster that is not the target environment's
CONTEXT="$(kubectl config current-context)"
if [[ "$CONTEXT" != *"petclinic-${ENV}"* ]]; then
  echo "ERROR: kubectl context '${CONTEXT}' does not look like petclinic-${ENV}." >&2
  echo "       Run: aws eks update-kubeconfig --name petclinic-${ENV} --region us-east-1" >&2
  exit 1
fi

REPLICAS=1
[[ "$ENV" == "prod" ]] && REPLICAS=2

echo "==> Reading Terraform outputs (${ENV})"
ROLE_ARN="$(terraform -chdir="$TF_DIR" output -raw lb_controller_role_arn)"
CLUSTER_NAME="$(terraform -chdir="$TF_DIR" output -raw eks_cluster_name)"
VPC_ID="$(terraform -chdir="$TF_DIR" output -raw vpc_id)"

echo "    cluster: ${CLUSTER_NAME}"
echo "    vpc:     ${VPC_ID}"
echo "    role:    ${ROLE_ARN}"
echo "    context: $(kubectl config current-context)"

echo "==> Adding Helm repo"
helm repo add eks https://aws.github.io/eks-charts --force-update >/dev/null
helm repo update eks >/dev/null

# Helm installs CRDs only on first install and never upgrades them, so apply them
# from the same chart version first.
echo "==> Applying CRDs (chart ${CHART_VERSION})"
helm show crds eks/aws-load-balancer-controller --version "$CHART_VERSION" | kubectl apply -f -

echo "==> Installing controller"
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" \
  --set clusterName="$CLUSTER_NAME" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.create=true \
  --set serviceAccount.name="$SERVICE_ACCOUNT" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${ROLE_ARN}" \
  --set replicaCount="$REPLICAS" \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=128Mi \
  --set resources.limits.memory=256Mi \
  --set "defaultTags.Project=petclinic" \
  --set "defaultTags.Environment=${ENV}" \
  --set "defaultTags.ManagedBy=aws-load-balancer-controller" \
  --wait --timeout 5m

echo "==> Status"
kubectl -n "$NAMESPACE" rollout status deploy/aws-load-balancer-controller --timeout=120s
kubectl -n "$NAMESPACE" get deploy aws-load-balancer-controller
kubectl get ingressclass alb
