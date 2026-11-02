# Kubernetes Base Manifests and Overlays

**Last Updated:** 2026-10-29

**Purpose:** How the base manifests and the dev and prod overlays are organized, how to validate and apply them, and which settings become `helm-values/dev.yaml` and `helm-values/prod.yaml` later (PETPLAT-38 to PETPLAT-47).

## Table of Contents

1. [Layout](#layout)
2. [Validate and apply](#validate-and-apply)
3. [Startup order](#startup-order)
4. [Settings per environment](#settings-per-environment)
5. [Translation to Helm values](#translation-to-helm-values)
6. [Before the first deploy](#before-the-first-deploy)

## Layout

```
k8s/
├── base/
│   ├── namespaces.yaml            # petclinic-dev and petclinic-prod, applied once on its own
│   ├── kustomization.yaml         # the 8 services (not the namespaces)
│   └── {service}/                 # deployment, service, configmap, serviceaccount, kustomization
└── overlays/
    ├── dev/                       # namespace, 1 replica, dev ECR images, dev RDS endpoint, quota
    └── prod/                      # namespace, HA replicas, prod images, HPA, PDB, quota
```

Base manifests carry `namespace: petclinic-dev` as a default. The overlay `namespace:` setting replaces it, so prod resources land in `petclinic-prod`.

## Validate and apply

Run from the repo root.

```bash
kubectl apply --dry-run=client -f k8s/base/namespaces.yaml
kubectl apply --dry-run=client -k k8s/overlays/dev
kubectl apply --dry-run=client -k k8s/overlays/prod
kubectl kustomize k8s/overlays/dev
```

To deploy dev (after the steps in [Before the first deploy](#before-the-first-deploy)):

```bash
kubectl apply -f k8s/base/namespaces.yaml
kubectl apply -f k8s/base/external-secrets/rds-credentials.yaml -f k8s/base/external-secrets/openai-api-key.yaml
kubectl apply -k k8s/overlays/dev
kubectl get po -n petclinic-dev -w
```

## Startup order

Init containers (`busybox:1.36`, a `wget` loop every 5s) enforce the order from the spec.

| Service | Waits for |
|---------|-----------|
| config-server | nothing (starts first) |
| discovery-server | config-server |
| api-gateway, customers-service, vets-service, genai-service, admin-server | config-server, then discovery-server |
| visits-service | config-server, discovery-server, then customers-service (spec: visits starts after customers) |

Every Deployment has a startupProbe (`/actuator/health`, up to 5 minutes), a readinessProbe and a livenessProbe. Config Server uses `/actuator/health` for all three.

## Settings per environment

| Setting | Dev | Prod |
|---------|-----|------|
| Namespace | `petclinic-dev` | `petclinic-prod` |
| Replicas | 1 for every service | config, discovery, api-gateway, customers, visits, vets: 2; genai, admin: 1 |
| HPA | none | api-gateway 2-6; customers, visits, vets 2-4; genai 1-3; CPU target 70% |
| PDB | none | `minAvailable: 1` for config, discovery, api-gateway, customers, visits, vets |
| ResourceQuota | requests 4 CPU, 4Gi, 30 pods | same |
| Images | `{account}.dkr.ecr.us-east-1.amazonaws.com/petclinic-dev/{service}:{sha}` | `.../petclinic-prod/{service}:{sha}` |
| RDS endpoint | dev RDS | placeholder until prod RDS exists |
| Container resources | from the spec table (same as base) | same; the spec gives no larger numbers |

The quota is on **requests** because the spec limits (512Mi each) cannot fit 8 services under 4Gi. At the HPA maximum, prod needs 26 pods and 3.2 CPU of requests, which stays under the quota. The two t4g.small nodes cannot run that many pods, so the HPA maximum needs Karpenter (see the spec).

## Translation to Helm values

When the Helm chart exists (E-16), express the overlays like this.

| Overlay setting | `helm-values/dev.yaml` | `helm-values/prod.yaml` |
|-----------------|------------------------|-------------------------|
| `replicas:` | `replicaCount: 1` | `replicaCount: 2` (genai, admin: 1) |
| HPA | `autoscaling.enabled: false` | `autoscaling.enabled: true`, min/max per service from the table |
| PDB | `pdb.enabled: false` | `pdb.enabled: true`, `minAvailable: 1` |
| Quota | `resourceQuota.requests.cpu: "4"`, `.memory: 4Gi`, `.pods: 30` | same |
| `images:` | `image.repository: {account}.dkr.ecr...petclinic-dev/{service}` | `...petclinic-prod/{service}` |
| `newTag` | `image.tag` (CI commits the SHA here) | `image.tag` |
| Datasource patch | env `SPRING_DATASOURCE_URL` | env `SPRING_DATASOURCE_URL` |

## Before the first deploy

1. **Images in ECR** with the tag you put in `newTag` (PETPLAT-85). The overlays use the placeholder `REPLACE_WITH_SHA`; replace it with the real commit SHA.
2. **Secrets synced.** The `rds-credentials` and `openai-api-key` Secrets must exist in the namespace (see `docs/external-secrets.md`).
3. **Metrics Server** for the prod HPA (PETPLAT-72). It is not installed yet.
4. **Prod only:** replace `REPLACE-WITH-PROD-RDS-ID` in `k8s/overlays/prod/kustomization.yaml` with the real prod RDS endpoint. **Do not sync prod before this**: customers, visits and vets cannot reach the database until it is set.
5. **Namespace labels:** `petclinic-dev` was created by hand. Applying `namespaces.yaml` adds the labels and Pod Security levels to it.

## Known limits

| Limit | Why it matters | What to do |
|-------|----------------|------------|
| Prod pods near the HPA maximum | At 26 pods the quota allows 30. A rolling update (default 25% surge) over 8 Deployments can need about 9 extra pods and stall | Raise `pods` in the quota (update the spec table too) or set `maxSurge: 0` for prod |
| HPA versus `replicas:` | The HPA owns `spec.replicas` for api-gateway, customers, visits, vets, genai, so ArgoCD shows drift | In the prod ArgoCD Application, add `ignoreDifferences` on `/spec/replicas` for those 5 Deployments |
| Node capacity | 14 pods at steady state request 1792Mi and 1600m on 2 t4g.small nodes (about 1.2 to 1.4 GiB allocatable each), plus add-ons | After the first sync run `kubectl describe nodes` and check Allocated resources; use Karpenter or a larger instance if pods stay Pending |
| Actuator probes | `/actuator/health/readiness` and `/liveness` exist only when Spring Boot probes are enabled (automatic on Kubernetes) | Confirm in the config repo if a pod never becomes Ready |
