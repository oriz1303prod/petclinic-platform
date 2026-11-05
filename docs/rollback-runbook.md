# Rollback Runbook

**Last Updated:** 2026-11-05
**Purpose:** Step-by-step procedures to rollback a failed deployment using GitOps (preferred), ArgoCD, or kubectl emergency fallback.

---

## Table of Contents

1. [Decision: Which Rollback Method](#decision-which-rollback-method)
2. [Method 1: GitOps Rollback (Preferred)](#method-1-gitops-rollback-preferred)
3. [Method 2: ArgoCD Rollback](#method-2-argocd-rollback)
4. [Method 3: kubectl Emergency Rollback](#method-3-kubectl-emergency-rollback)
5. [Post-Rollback Verification](#post-rollback-verification)
6. [Rollback Scenarios](#rollback-scenarios)

---

## Decision: Which Rollback Method

| Situation | Method | Why |
|-----------|--------|-----|
| Bad image deployed, Git history is clean | GitOps revert | Keeps Git as source of truth |
| Need immediate rollback, can't wait for CI | ArgoCD rollback | Faster, no Git commit needed |
| ArgoCD is down or unreachable | kubectl rollout undo | Last resort, bypasses GitOps |

---

## Method 1: GitOps Rollback (Preferred)

**When:** A bad image tag was committed to `helm-values/` and ArgoCD deployed it.
**Who:** Any engineer with push access to the platform repo.
**Time:** ~2-5 minutes (commit + ArgoCD sync).

### Steps:

1. Identify the bad commit:

```bash
git log --oneline helm-values/ | head -5
```

2. Revert the image tag commit:

```bash
git revert <bad-commit-sha> --no-edit
git push
```

3. ArgoCD detects the revert commit:
   - **Dev:** Auto-syncs immediately (prune + self-heal enabled).
   - **Prod:** Queues sync — approve manually in ArgoCD UI or CLI:

```bash
argocd app sync {service}-prod
```

### Verify:

```bash
kubectl get pods -n petclinic-{env} -l app.kubernetes.io/name={service}
kubectl rollout status deployment/{service} -n petclinic-{env}
```

### Rollback of the rollback:

If the revert was wrong, revert the revert:

```bash
git revert <revert-commit-sha> --no-edit
git push
```

---

## Method 2: ArgoCD Rollback

**When:** Need a faster rollback without touching Git, or multiple commits need to be unwound.
**Who:** Engineer with ArgoCD access.
**Time:** ~1-2 minutes.

### Steps:

1. Access ArgoCD:

```bash
kubectl port-forward svc/argocd-server -n argocd 8443:443
```

2. List application history:

```bash
argocd app history {service}-{env}
```

3. Rollback to the previous revision:

```bash
argocd app rollback {service}-{env} <revision-number>
```

4. For dev (auto-sync), disable auto-sync first to prevent ArgoCD from re-syncing the bad tag:

```bash
argocd app set {service}-dev --sync-policy none
argocd app rollback {service}-dev <revision-number>
```

5. After fixing the image tag in Git, re-enable auto-sync:

```bash
argocd app set {service}-dev --sync-policy automated --auto-prune --self-heal
```

### Verify:

```bash
argocd app get {service}-{env}
kubectl get pods -n petclinic-{env} -l app.kubernetes.io/name={service}
```

### Important:

ArgoCD rollback is temporary if auto-sync is enabled — ArgoCD will re-sync from Git on the next change. Always follow up by fixing the image tag in Git.

---

## Method 3: kubectl Emergency Rollback

**When:** ArgoCD is unreachable or broken. Last resort only — this bypasses GitOps.
**Who:** Engineer with kubectl cluster access.
**Time:** ~30 seconds.

### Steps:

1. Rollback the deployment:

```bash
kubectl rollout undo deployment/{service} -n petclinic-{env}
```

2. To rollback to a specific revision:

```bash
kubectl rollout history deployment/{service} -n petclinic-{env}
kubectl rollout undo deployment/{service} -n petclinic-{env} --to-revision=<number>
```

### Verify:

```bash
kubectl rollout status deployment/{service} -n petclinic-{env}
kubectl get pods -n petclinic-{env} -l app.kubernetes.io/name={service}
```

### Important:

ArgoCD will detect drift and attempt to re-sync. You must also fix the image tag in Git or disable auto-sync to prevent ArgoCD from redeploying the bad version.

---

## Post-Rollback Verification

Run these checks after any rollback method:

```bash
# All pods running and ready
kubectl get pods -n petclinic-{env}

# Service health
kubectl exec -n petclinic-{env} deploy/{service} -- wget -qO- http://localhost:{port}/actuator/health

# Check Eureka registration (all services should appear)
kubectl exec -n petclinic-{env} deploy/discovery-server -- wget -qO- http://localhost:8761/eureka/apps

# Run smoke test
scripts/smoke-test.sh petclinic-{env}
```

---

## Rollback Scenarios

### Scenario: Single service broken after image update

1. Identify which service is failing:

```bash
kubectl get pods -n petclinic-{env} | grep -v Running
kubectl logs -n petclinic-{env} deploy/{service} --tail=50
```

2. Use GitOps rollback for that service only:

```bash
# Edit the specific service's values file to restore the previous tag
git log --oneline helm-values/{service}.yaml | head -3
git revert <commit-that-changed-this-service> --no-edit
git push
```

### Scenario: Multiple services broken after bulk update

1. Revert the entire image tag update commit:

```bash
git log --oneline helm-values/ | head -3
git revert <bulk-update-commit> --no-edit
git push
```

2. All services revert to their previous tags. ArgoCD syncs each one.

### Scenario: Config Server down, cascading failures

Config Server is a critical dependency. If it fails, all other services lose config on restart.

1. Rollback Config Server immediately:

```bash
kubectl rollout undo deployment/config-server -n petclinic-{env}
```

2. Verify Config Server is healthy:

```bash
kubectl exec -n petclinic-{env} deploy/config-server -- wget -qO- http://localhost:8888/actuator/health
```

3. Restart affected services that are stuck in init container wait loops:

```bash
kubectl rollout restart deployment/{service} -n petclinic-{env}
```

4. Fix the image tag in Git to prevent ArgoCD from redeploying the bad version.

### Scenario: RDS connection failure after deployment

Not a rollback issue — check RDS connectivity:

```bash
kubectl run -n petclinic-{env} debug --rm -it --image=mysql:8 -- \
  mysql -h <rds-endpoint> -u petclinic -p
```

If the issue is in the new image (wrong datasource config), rollback the service image.
