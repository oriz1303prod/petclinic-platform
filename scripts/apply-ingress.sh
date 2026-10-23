#!/usr/bin/env bash
set -euo pipefail

#
# apply-ingress.sh — Render and apply the API Gateway Ingress (PETPLAT-30)
#
# Fills the placeholders in k8s/base/ingress/ingress.yaml from Terraform outputs
# and applies it. Run after install-lb-controller.sh and after api-gateway is deployed.
#
# Usage:
#   ./scripts/apply-ingress.sh dev            # server-side dry run only
#   ./scripts/apply-ingress.sh dev --apply    # really apply
#

usage() {
  echo "Usage: $0 <environment> [--apply]"
  echo "  environment: dev | prod"
  exit 1
}

if [[ $# -lt 1 || $# -gt 2 ]] || [[ "$1" != "dev" && "$1" != "prod" ]]; then
  usage
fi

ENV="$1"
MODE="--dry-run=server"
if [[ "${2:-}" == "--apply" ]]; then
  MODE=""
elif [[ -n "${2:-}" ]]; then
  usage
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="${ROOT}/terraform/environments/${ENV}"

for cmd in terraform kubectl envsubst; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd not found in PATH" >&2; exit 1; }
done

# Refuse to write to a cluster that is not the target environment's
CONTEXT="$(kubectl config current-context)"
if [[ "$CONTEXT" != *"petclinic-${ENV}"* ]]; then
  echo "ERROR: kubectl context '${CONTEXT}' does not look like petclinic-${ENV}." >&2
  echo "       Run: aws eks update-kubeconfig --name petclinic-${ENV} --region us-east-1" >&2
  exit 1
fi

K8S_NAMESPACE="petclinic-${ENV}"
ALB_NAME="$(terraform -chdir="$TF_DIR" output -raw alb_name)"
ALB_SG_ID="$(terraform -chdir="$TF_DIR" output -raw alb_sg_id)"
ACM_CERTIFICATE_ARN="$(terraform -chdir="$TF_DIR" output -raw acm_certificate_arn 2>/dev/null || true)"
APP_FQDN="$(terraform -chdir="$TF_DIR" output -raw app_fqdn 2>/dev/null || true)"

if [[ -z "$ACM_CERTIFICATE_ARN" || -z "$APP_FQDN" ]]; then
  echo "ERROR: no certificate or hostname in Terraform outputs (is enable_dns false, or the full apply not done?)." >&2
  echo "       See docs/dns-cloudflare-delegation.md." >&2
  exit 1
fi
export K8S_NAMESPACE ALB_NAME ALB_SG_ID ACM_CERTIFICATE_ARN APP_FQDN

echo "==> Ingress for https://${APP_FQDN} in ${K8S_NAMESPACE}"
# Restrict envsubst to our variables so other $ signs are left alone
envsubst '${K8S_NAMESPACE} ${ALB_NAME} ${ALB_SG_ID} ${ACM_CERTIFICATE_ARN} ${APP_FQDN}' \
  < "${ROOT}/k8s/base/ingress/ingress.yaml" \
  | kubectl apply ${MODE} -f -

if [[ -z "$MODE" ]]; then
  echo "==> Applied. The ALB takes 2-3 minutes:"
  echo "    kubectl get ingress api-gateway -n ${K8S_NAMESPACE}"
else
  echo "==> Dry run only. Add --apply to create it."
fi
