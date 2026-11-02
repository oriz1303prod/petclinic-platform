#!/usr/bin/env bash
set -euo pipefail

#
# validate-helm.sh — Validate the Petclinic Helm chart for all services and environments
#
# For every service x environment (8 x 2 = 16 releases) it runs:
#   1. helm lint
#   2. helm template (service values, then env values)
#   3. checks on the rendered output (kinds, replicas, HPA, PDB, ports, secrets, no :latest)
#   4. kubectl apply --dry-run=client on the rendered output
#
# Run from anywhere; paths are resolved from the repo root.
# kubectl needs access to a cluster for the dry run (the API server is used for discovery).
#
# Usage:
#   ./scripts/validate-helm.sh                                     # all services, dev and prod
#   ./scripts/validate-helm.sh --service customers-service         # one service, dev and prod
#   ./scripts/validate-helm.sh --env prod                          # all services, prod only
#   ./scripts/validate-helm.sh --service customers-service --env prod
#

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="${ROOT}/helm/petclinic-service"
VALUES="${ROOT}/helm-values"

ALL_SERVICES=(config-server discovery-server api-gateway customers-service visits-service vets-service genai-service admin-server)
ALL_ENVS=(dev prod)

# Expected values (must match k8s/overlays/prod and the service table in the spec)
port_of()      { case "$1" in config-server) echo 8888;; discovery-server) echo 8761;; api-gateway) echo 8080;; customers-service) echo 8081;; visits-service) echo 8082;; vets-service) echo 8083;; genai-service) echo 8084;; admin-server) echo 9090;; esac; }
replicas_of()  { # $1 service, $2 env
  if [[ "$2" == "dev" ]]; then echo 1; return; fi
  case "$1" in genai-service|admin-server) echo 1;; *) echo 2;; esac
}
hpa_range_of() { # prints "min max" or nothing when the service has no HPA in prod
  case "$1" in api-gateway) echo "2 6";; customers-service|visits-service|vets-service) echo "2 4";; genai-service) echo "1 3";; esac
}
has_pdb()      { case "$1" in genai-service|admin-server) return 1;; *) return 0;; esac; }
has_db()       { case "$1" in customers-service|visits-service|vets-service) return 0;; *) return 1;; esac; }

usage() {
  echo "Usage: $0 [--service <name>] [--env dev|prod]"
  echo "  service: one of ${ALL_SERVICES[*]}"
  exit 1
}

SERVICES=("${ALL_SERVICES[@]}")
ENVS=("${ALL_ENVS[@]}")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --service)
      [[ $# -ge 2 ]] || usage
      [[ " ${ALL_SERVICES[*]} " == *" $2 "* ]] || { echo "Error: unknown service '$2'"; usage; }
      SERVICES=("$2"); shift 2;;
    --env)
      [[ $# -ge 2 ]] || usage
      [[ " ${ALL_ENVS[*]} " == *" $2 "* ]] || { echo "Error: environment must be dev or prod"; usage; }
      ENVS=("$2"); shift 2;;
    -h|--help) usage;;
    *) echo "Error: unknown argument '$1'"; usage;;
  esac
done

for tool in helm kubectl; do
  command -v "$tool" >/dev/null || { echo "Error: $tool is not installed"; exit 1; }
done

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

PASS=0
FAIL=0
fail() { echo "    FAIL: $*"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

count_kind() { grep -c "^kind: $2\$" "$1" || true; }

echo "============================================"
echo "  Validating Helm chart: ${CHART#"$ROOT"/}"
echo "  Services: ${SERVICES[*]}"
echo "  Environments: ${ENVS[*]}"
echo "============================================"

for env in "${ENVS[@]}"; do
  for svc in "${SERVICES[@]}"; do
    name="${svc}/${env}"
    file="${OUT}/${svc}-${env}.yaml"
    args=(-f "${VALUES}/${svc}.yaml" -f "${VALUES}/${env}.yaml")
    echo ""
    echo "--- ${name}"

    # 1. lint
    if helm lint "$CHART" "${args[@]}" >"${OUT}/lint.txt" 2>&1; then pass; else fail "helm lint"; cat "${OUT}/lint.txt"; continue; fi

    # 2. template (release name = service name, like the ArgoCD Application)
    if helm template "$svc" "$CHART" "${args[@]}" >"$file" 2>"${OUT}/template.err"; then pass; else fail "helm template"; cat "${OUT}/template.err"; continue; fi

    # 3. checks on the rendered output
    ns="petclinic-${env}"
    [[ "$(count_kind "$file" Deployment)" == 1 ]]     && pass || fail "expected 1 Deployment"
    [[ "$(count_kind "$file" Service)" == 1 ]]        && pass || fail "expected 1 Service"
    [[ "$(count_kind "$file" ConfigMap)" == 1 ]]      && pass || fail "expected 1 ConfigMap"
    [[ "$(count_kind "$file" ServiceAccount)" == 1 ]] && pass || fail "expected 1 ServiceAccount"

    grep -q "^  namespace: ${ns}\$" "$file" && pass || fail "namespace is not ${ns}"
    [[ "$(grep -c '^  namespace:' "$file")" -ge 4 ]] && pass || fail "a resource has no namespace"

    # With an HPA the Deployment has no replicas field (the HPA minReplicas is the starting size)
    if [[ "$env" == "prod" && -n "$(hpa_range_of "$svc")" ]]; then
      grep -q '^  replicas:' "$file" && fail "replicas must not be set when an HPA is enabled" || pass
    else
      grep -q "^  replicas: $(replicas_of "$svc" "$env")\$" "$file" && pass || fail "replicas should be $(replicas_of "$svc" "$env")"
    fi
    grep -q "containerPort: $(port_of "$svc")\$" "$file" && pass || fail "containerPort should be $(port_of "$svc")"
    grep -q "port: $(port_of "$svc")\$" "$file" && pass || fail "Service port should be $(port_of "$svc")"
    grep -q "image: 533267001265.dkr.ecr.us-east-1.amazonaws.com/petclinic-${env}/${svc}:[A-Za-z0-9_.-]*\$" "$file" && pass || fail "image should come from petclinic-${env}/${svc}"
    if grep -q ':latest' "$file"; then fail "image tag latest is not allowed"; else pass; fi

    for probe in startupProbe readinessProbe livenessProbe; do
      grep -q "${probe}:" "$file" && pass || fail "missing ${probe}"
    done
    grep -q 'requests:' "$file" && grep -q 'limits:' "$file" && pass || fail "missing resources requests/limits"
    grep -q 'runAsNonRoot: true' "$file" && pass || fail "missing runAsNonRoot"
    grep -q 'app.kubernetes.io/part-of: petclinic' "$file" && pass || fail "missing part-of label"

    # Secrets: exact names and keys from k8s/base
    if has_db "$svc"; then
      grep -q 'name: rds-credentials' "$file" && grep -q 'key: username' "$file" && grep -q 'key: password' "$file" && pass || fail "rds-credentials secret references missing"
      grep -q 'SPRING_DATASOURCE_URL: "jdbc:mysql://' "$file" && pass || fail "SPRING_DATASOURCE_URL missing"
    fi
    if [[ "$svc" == "genai-service" ]]; then
      grep -q 'name: openai-api-key' "$file" && grep -q 'key: OPENAI_API_KEY' "$file" && pass || fail "openai-api-key secret reference missing"
    fi

    # HPA: prod only, and only for the 5 services in the overlay
    hpa_count="$(count_kind "$file" HorizontalPodAutoscaler)"
    range="$(hpa_range_of "$svc")"
    if [[ "$env" == "prod" && -n "$range" ]]; then
      read -r hmin hmax <<<"$range"
      [[ "$hpa_count" == 1 ]] && grep -q "minReplicas: ${hmin}\$" "$file" && grep -q "maxReplicas: ${hmax}\$" "$file" && grep -q 'averageUtilization: 70' "$file" && pass || fail "HPA should be ${hmin}-${hmax} at 70% CPU"
    else
      [[ "$hpa_count" == 0 ]] && pass || fail "unexpected HPA"
    fi

    # PDB: prod only, minAvailable 1, 6 services
    pdb_count="$(count_kind "$file" PodDisruptionBudget)"
    if [[ "$env" == "prod" ]] && has_pdb "$svc"; then
      [[ "$pdb_count" == 1 ]] && grep -q 'minAvailable: 1$' "$file" && pass || fail "PDB with minAvailable 1 expected"
    else
      [[ "$pdb_count" == 0 ]] && pass || fail "unexpected PDB"
    fi

    # 4. kubectl dry run
    if kubectl apply --dry-run=client -f "$file" >"${OUT}/dry.txt" 2>&1; then pass; else fail "kubectl apply --dry-run=client"; cat "${OUT}/dry.txt"; fi
    echo "    done"
  done
done

# Totals across the whole prod set (only when all services were rendered)
if [[ ${#SERVICES[@]} -eq ${#ALL_SERVICES[@]} && " ${ENVS[*]} " == *" prod "* ]]; then
  hpas=0; pdbs=0
  for svc in "${SERVICES[@]}"; do
    hpas=$((hpas + $(count_kind "${OUT}/${svc}-prod.yaml" HorizontalPodAutoscaler)))
    pdbs=$((pdbs + $(count_kind "${OUT}/${svc}-prod.yaml" PodDisruptionBudget)))
  done
  echo ""
  echo "--- prod totals"
  [[ "$hpas" == 5 ]] && pass || fail "expected 5 HPAs in prod, found ${hpas}"
  [[ "$pdbs" == 6 ]] && pass || fail "expected 6 PDBs in prod, found ${pdbs}"
  echo "    HPAs: ${hpas}, PDBs: ${pdbs}"
fi

echo ""
echo "============================================"
echo "  Checks passed: ${PASS}"
echo "  Checks failed: ${FAIL}"
echo "============================================"
[[ "$FAIL" -eq 0 ]]
