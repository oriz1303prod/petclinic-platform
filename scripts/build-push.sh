#!/usr/bin/env bash
set -euo pipefail

#
# build-push.sh — Build the 8 Petclinic JARs with Maven, then build and push
# linux/arm64 images to ECR with docker buildx (Graviton t4g nodes).
#
# Maven only builds the JARs. Images are NOT built with Maven's buildDocker profile.
# The application repo is read-only: this script only reads from it.
#
# Usage:
#   ./scripts/build-push.sh <env> <tag> [app-repo-path] [service ...]
#
# Examples:
#   ./scripts/build-push.sh dev v1.0.0                      # all 8 services
#   ./scripts/build-push.sh dev v1.0.0 ../spring-petclinic-microservices
#   ./scripts/build-push.sh dev v1.0.0 api-gateway          # one service
#
# Environment variables:
#   APP_REPO         Path to the application repo (default: ../spring-petclinic-microservices)
#   SKIP_MAVEN=1     Reuse existing JARs instead of running Maven
#   AWS_DEFAULT_REGION  Registry region (default: us-east-1)
#

REGION="${AWS_DEFAULT_REGION:-us-east-1}"
PLATFORM="linux/arm64"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_REPO="${APP_REPO:-${SCRIPT_DIR}/../../spring-petclinic-microservices}"

# service -> runtime port (from the technical spec; do NOT use the pom exposed ports)
declare -a ALL_SERVICES=(
  "config-server:8888"
  "discovery-server:8761"
  "api-gateway:8080"
  "customers-service:8081"
  "visits-service:8082"
  "vets-service:8083"
  "genai-service:8084"
  "admin-server:9090"
)

usage() {
  echo "Usage: $0 <environment> <tag> [app-repo-path] [service ...]"
  echo "  environment: dev | prod"
  echo "  tag:         image tag, e.g. v1.0.0 or a 7-char commit SHA (never 'latest')"
  echo "  app-repo-path: optional path to the application repo (overrides APP_REPO)"
  echo "  service:     optional subset of the 8 services (default: all)"
  exit 1
}

[[ $# -ge 2 ]] || usage
ENV="$1"
TAG="$2"
shift 2

# Optional app repo path: any existing directory given before the service names
if [[ $# -gt 0 && -d "$1" ]]; then
  APP_REPO="$1"
  shift
fi

if [[ "$ENV" != "dev" && "$ENV" != "prod" ]]; then
  echo "Error: environment must be 'dev' or 'prod'"
  usage
fi
if [[ "$TAG" == "latest" ]]; then
  echo "Error: the 'latest' tag is not allowed"
  exit 1
fi

for cmd in aws docker; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: '$cmd' is not installed"; exit 1; }
done
docker buildx version >/dev/null 2>&1 || { echo "Error: docker buildx is not available"; exit 1; }
[[ -d "$APP_REPO" ]] || { echo "Error: application repo not found at $APP_REPO (set APP_REPO)"; exit 1; }
APP_REPO="$(cd "$APP_REPO" && pwd)"

# Select services
declare -a SELECTED=()
if [[ $# -eq 0 ]]; then
  SELECTED=("${ALL_SERVICES[@]}")
else
  for want in "$@"; do
    found=""
    for entry in "${ALL_SERVICES[@]}"; do
      if [[ "${entry%%:*}" == "$want" ]]; then found="$entry"; fi
    done
    [[ -n "$found" ]] || { echo "Error: unknown service '$want'"; exit 1; }
    SELECTED+=("$found")
  done
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# 1. Build the JARs (no Docker involved)
if [[ "${SKIP_MAVEN:-0}" != "1" ]]; then
  echo "==> Building JARs with Maven"
  (cd "$APP_REPO" && ./mvnw clean package -DskipTests)
fi

# 2. Log in to ECR
echo "==> Logging in to ${REGISTRY}"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

# 3. Build and push each image
for entry in "${SELECTED[@]}"; do
  svc="${entry%%:*}"
  port="${entry##*:}"
  module_dir="${APP_REPO}/spring-petclinic-${svc}"
  jar_path="$(ls "${module_dir}"/target/spring-petclinic-"${svc}"-*.jar 2>/dev/null | grep -v '\.original$' | head -n 1 || true)"

  if [[ -z "$jar_path" ]]; then
    echo "Error: no JAR found for ${svc} in ${module_dir}/target (run without SKIP_MAVEN)"
    exit 1
  fi
  artifact="$(basename "$jar_path" .jar)"
  image="${REGISTRY}/petclinic-${ENV}/${svc}:${TAG}"

  echo "==> ${svc}: building ${PLATFORM} image ${image}"
  docker buildx build \
    --platform "$PLATFORM" \
    --provenance=false \
    --sbom=false \
    -f "${APP_REPO}/docker/Dockerfile" \
    --build-arg "ARTIFACT_NAME=${artifact}" \
    --build-arg "EXPOSED_PORT=${port}" \
    -t "$image" \
    --push \
    "${module_dir}/target"
done

echo "==> Done. Pushed ${#SELECTED[@]} image(s) with tag ${TAG}"
