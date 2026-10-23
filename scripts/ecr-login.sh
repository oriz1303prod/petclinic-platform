#!/usr/bin/env bash
set -euo pipefail

#
# ecr-login.sh — Authenticate Docker to the ECR private registry
#
# Usage:
#   ./scripts/ecr-login.sh
#   ./scripts/ecr-login.sh --region us-east-1
#

REGION="us-east-1"

usage() {
  echo "Usage: $0 [--region <aws-region>]"
  echo "  --region   AWS region of the registry (default: us-east-1)"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      [[ $# -ge 2 ]] || usage
      REGION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Error: unknown argument '$1'"
      usage
      ;;
  esac
done

for cmd in aws docker; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' is not installed or not in PATH"
    exit 1
  fi
done

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

echo "Logged in to ${REGISTRY}"
