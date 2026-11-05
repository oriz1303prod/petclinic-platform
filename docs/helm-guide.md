# Helm Chart Guide

**Last Updated:** 2026-10-30

**Purpose:** How the generic Helm chart for the 8 Petclinic services is built, how the values files merge, and how to deploy, add or change a service (PETPLAT-107 to 111). The chart renders the same resources as `k8s/base` and `k8s/overlays`; ArgoCD deploys it.

## Table of Contents

1. [Layout](#layout)
2. [Values hierarchy](#values-hierarchy)
3. [Key values](#key-values)
4. [Procedure: validate the chart](#procedure-validate-the-chart)
5. [Procedure: deploy a service manually](#procedure-deploy-a-service-manually)
6. [Procedure: change resources, replicas or environment variables](#procedure-change-resources-replicas-or-environment-variables)
7. [Procedure: add a new service](#procedure-add-a-new-service)
8. [ArgoCD integration](#argocd-integration)
9. [Moving a namespace from Kustomize to Helm](#moving-a-namespace-from-kustomize-to-helm)
10. [Known limits](#known-limits)

## Layout

```
helm/petclinic-service/        # one chart for all 8 services
├── Chart.yaml
├── values.yaml                # defaults
└── templates/
    ├── deployment.yaml        # probes, resources, init containers, secrets, securityContext
    ├── service.yaml           # ClusterIP
    ├── configmap.yaml         # non-secret env (CONFIG_SERVER_URL, SPRING_DATASOURCE_URL, ...)
    ├── serviceaccount.yaml    # automountServiceAccountToken false, optional IRSA annotation
    ├── hpa.yaml               # only when autoscaling.enabled
    ├── pdb.yaml               # only when podDisruptionBudget.enabled
    ├── _helpers.tpl           # names, labels, selector, image, effective values
    └── NOTES.txt
helm-values/
├── {service}.yaml             # 8 files: port, image name, profiles, secrets, init containers
├── dev.yaml                   # namespace, registry, 1 replica, no HPA/PDB, dev RDS host
└── prod.yaml                  # namespace, registry, 2 replicas, per-service HPA/PDB, prod RDS host
```

The ResourceQuota is one object per namespace, not per service, so it is not in the chart. It stays in `k8s/overlays/{env}/resourcequota.yaml`.

## Values hierarchy

Merge order, last wins:

1. `helm/petclinic-service/values.yaml` (defaults)
2. `helm-values/{service}.yaml` (service-specific)
3. `helm-values/{env}.yaml` (environment-specific)
4. `serviceOverrides.{service}` inside the env file (per-service exceptions for that environment)

Step 4 is how prod gets different replicas, HPA and PDB per service from a single `prod.yaml`. The chart reads `serviceOverrides.<serviceName>` and merges it over everything else.

## Key values

| Key | Set in | Meaning |
|-----|--------|---------|
| `serviceName` | service file | Name of the Deployment, Service, ServiceAccount; ConfigMap is `{serviceName}-config` |
| `component` | service file | `app.kubernetes.io/component`: service, server, gateway or admin |
| `service.port` | service file | Service and container port (8888, 8761, 8080, 8081, 8082, 8083, 8084, 9090) |
| `image.name` | service file | ECR image name, for example `customers-service` |
| `image.tag` | service file | Commit SHA (CI updates it). Default `REPLACE_WITH_SHA` fails visibly, never `latest` |
| `image.registry` | env file | `{account}.dkr.ecr.us-east-1.amazonaws.com/petclinic-{env}` |
| `springProfiles` | service file | `SPRING_PROFILES_ACTIVE`, for example `docker,mysql` |
| `config` | service file | ConfigMap data (non-secret) |
| `database.enabled` | service file | true for customers, visits, vets; adds `SPRING_DATASOURCE_URL` |
| `database.host` | env file | RDS endpoint for that environment |
| `secrets` | service file | `[{name, secretName, key}]`, rendered as `secretKeyRef`. The Secrets come from External Secrets |
| `env` | service file | Extra static variables `[{name, value}]` |
| `initContainers` | service file | `[{name, url}]`, rendered as busybox wait-for loops |
| `resources` | service file | Defaults 100m/128Mi request, 500m/512Mi limit; api-gateway 200m/1000m CPU |
| `replicaCount`, `autoscaling`, `podDisruptionBudget` | env file | See the prod table in the technical spec |

With an HPA enabled the Deployment has no `replicas` field; the HPA `minReplicas` is the starting size.

## Procedure: validate the chart

**When:** after any change to `helm/` or `helm-values/`.
**Who:** anyone with `helm` and `kubectl` (cluster access for the dry run).
**Time:** about 1 minute.

**Steps:**
1. Validate all 16 releases (8 services x dev, prod): lint, render, checks, dry run.
   ```bash
   ./scripts/validate-helm.sh
   ```
2. Or validate one release.
   ```bash
   ./scripts/validate-helm.sh --service customers-service --env prod
   ```
3. Look at the rendered output.
   ```bash
   helm template customers-service helm/petclinic-service/ -f helm-values/customers-service.yaml -f helm-values/dev.yaml
   ```

**Verify:**
- The script ends with `Checks failed: 0`
- `helm lint helm/petclinic-service/` prints `0 chart(s) failed`

**Rollback:**
- `git restore helm helm-values`

## Procedure: deploy a service manually

**When:** testing a service without ArgoCD, or before ArgoCD exists.
**Who:** operator with kubectl access to the cluster.
**Time:** 2 to 5 minutes per service (JVM startup).

**Steps:**
1. Make sure the namespace and the Secrets exist (see `docs/external-secrets.md`).
   ```bash
   kubectl get ns petclinic-{env}
   kubectl get secret -n petclinic-{env}
   ```
2. Deploy. The release name equals the service name.
   ```bash
   helm upgrade --install config-server helm/petclinic-service/ \
     -n petclinic-dev \
     -f helm-values/config-server.yaml \
     -f helm-values/dev.yaml \
     --set image.tag=v1.0.0

   helm upgrade --install discovery-server helm/petclinic-service/ \
     -n petclinic-dev \
     -f helm-values/discovery-server.yaml \
     -f helm-values/dev.yaml \
     --set image.tag=v1.0.0  

   helm upgrade --install customers-service helm/petclinic-service/ \
     -n petclinic-dev \
     -f helm-values/customers-service.yaml \
     -f helm-values/dev.yaml \
     --set image.tag=v1.0.0

   helm upgrade --install visits-service helm/petclinic-service/ \
     -n petclinic-dev \
     -f helm-values/visits-service.yaml \
     -f helm-values/dev.yaml \
     --set image.tag=v1.0.0

   helm upgrade --install vets-service helm/petclinic-service/ \
     -n petclinic-dev \
     -f helm-values/vets-service.yaml \
     -f helm-values/dev.yaml \
     --set image.tag=v1.0.0

   helm upgrade --install genai-service helm/petclinic-service/ \
     -n petclinic-dev \
     -f helm-values/genai-service.yaml \
     -f helm-values/dev.yaml \
     --set image.tag=v1.0.0

   helm upgrade --install admin-server helm/petclinic-service/ \
     -n petclinic-dev \
     -f helm-values/admin-server.yaml \
     -f helm-values/dev.yaml \
     --set image.tag=v1.0.0

   helm upgrade --install api-gateway helm/petclinic-service/ \
     -n petclinic-dev \
     -f helm-values/api-gateway.yaml \
     -f helm-values/dev.yaml \
     --set image.tag=v1.0.0
   ```
3. Deploy the services in start order, or all at once (init containers wait): config-server, discovery-server, then the rest.

**Verify:**
```bash
kubectl get po -n petclinic-dev
helm list -n petclinic-dev
```

**History:**
```bash
helm history customers-service -n petclinic-dev
```

**Rollback:**
```bash
helm rollback customers-service <revision-number> -n petclinic-dev
```

## Procedure: change resources, replicas or environment variables

**When:** a service needs a different size, count or setting.
**Who:** anyone with commit access (ArgoCD applies it).
**Time:** 5 minutes plus sync.

**Steps:**
1. Pick the right file:
   - One service in every environment (resources, env vars, profiles, secrets, init containers): `helm-values/{service}.yaml`
   - One environment (replicas, HPA, PDB, RDS host, registry): `helm-values/{env}.yaml`
   - One service in one environment (prod HPA range, replicas): `serviceOverrides.{service}` in `helm-values/{env}.yaml`
2. Edit the value.
3. Validate and look at the diff.
   ```bash
   ./scripts/validate-helm.sh --service {service} --env {env}
   ```
4. Commit. Dev syncs automatically; prod needs a manual sync in ArgoCD.

**Verify:** `kubectl get deploy {service} -n petclinic-{env} -o yaml` shows the new value.

**Rollback:** revert the commit and sync again.

## Procedure: add a new service

**When:** a ninth microservice is added.
**Who:** anyone with commit access.
**Time:** 30 minutes.

**Steps:**
1. Copy the closest service file and edit it.
   ```bash
   cp helm-values/vets-service.yaml helm-values/new-service.yaml
   ```
   Set `serviceName`, `component`, `service.port`, `image.name`, `image.tag`, `springProfiles`, `config`, `secrets` and `initContainers`.
2. Prod only: add `serviceOverrides.new-service` in `helm-values/prod.yaml` if it needs a different replica count, an HPA or a PDB.
3. Add the service name and expected values to `scripts/validate-helm.sh` (`ALL_SERVICES`, `port_of`, `replicas_of`, `hpa_range_of`, `has_pdb`, `has_db`).
4. Create the ECR repository: add the name to `service_names` in `terraform/environments/{env}/main.tf`, then `/terraform-plan {env}`.
5. Add one ArgoCD Application per environment in `k8s/argocd/applications/{dev,prod}/new-service.yaml` (see below).
6. Validate.
   ```bash
   ./scripts/validate-helm.sh --service new-service
   ```

**Verify:** the service shows `Healthy` in ArgoCD and `1/1 Running` in `kubectl get po`.

**Rollback:** delete the Application and the values file.

## ArgoCD integration

One Application per service per environment (16 in total). It points at the chart and lists the two values files; ArgoCD merges them in the order given.

```yaml
spec:
  source:
    repoURL: https://github.com/{your-username}/petclinic-platform.git
    targetRevision: main
    path: helm/petclinic-service
    helm:
      valueFiles:
        - ../../helm-values/{service}.yaml
        - ../../helm-values/{env}.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: petclinic-{env}
```

- **Dev:** `automated` sync with prune and self-heal. **Prod:** no `automated` block, sync by hand in the ArgoCD UI or with `argocd app sync {service}-prod`.
- **Image updates:** CI commits the new `image.tag` to `helm-values/{service}.yaml`. ArgoCD sees the Git change and syncs.
- **No `ignoreDifferences` for replicas:** the chart omits `replicas` when the HPA is on, so ArgoCD and the HPA do not fight.
- The Application name (`customers-service-dev`) becomes the Helm release name and the `app.kubernetes.io/instance` label. Resource names come from `serviceName`, so they stay `customers-service`.

## Moving a namespace from Kustomize to Helm

Helm refuses to take over objects that another tool created (`invalid ownership metadata`). `petclinic-dev` currently runs objects applied with `kubectl apply -k k8s/overlays/dev`, which use the same names as the chart.

1. Only one tool may manage a namespace. Pick Helm and stop using `kubectl apply -k` for it.
2. Remove the Kustomize-managed objects first (dev is fine to recreate; the rolling restart takes a few minutes). Use the names from `kubectl kustomize k8s/overlays/dev`:
   ```bash
   kubectl delete -k k8s/overlays/dev
   ```
   Keep the Secrets and the ResourceQuota if you still want them: apply the quota separately with `kubectl apply -f k8s/overlays/dev/resourcequota.yaml`.
3. Install with Helm or let ArgoCD sync.

The prod quota and namespaces stay outside the chart in both cases.

## Known limits

| Limit | Why it matters | What to do |
|-------|----------------|------------|
| Placeholders in prod | `REPLACE_WITH_SHA` and `REPLACE-WITH-PROD-RDS-ID` in `helm-values/prod.yaml` | Replace both before the first prod sync |
| Prod ExternalSecrets | `k8s/base/external-secrets/*.yaml` read `petclinic/dev/*`; copying them for prod without changing the keys makes prod read dev secrets | Use `petclinic/prod/*` keys for prod |
| Config Server probes | It uses `/actuator/health` for readiness and liveness, not the `/readiness` and `/liveness` sub-paths | Confirm the health groups before changing |
| HPA | Needs Metrics Server (PETPLAT-72, not installed) | Install it before the first prod sync |
| ECR account | Registry values use the real account `533267001265` | Keep them in sync with `terraform output` |
