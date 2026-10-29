# External Secrets Operator (ESO)

**Last Updated:** 2026-10-29

**Purpose:** How secrets flow from AWS Secrets Manager into Kubernetes, how to install ESO, and how to add a new secret. Covers PETPLAT-33 to PETPLAT-37.

## Table of Contents

1. [How it works](#how-it-works)
2. [Install ESO](#install-eso)
3. [Sync the application secrets](#sync-the-application-secrets)
4. [Test with a sample ExternalSecret](#test-with-a-sample-externalsecret)
5. [Add a new secret](#add-a-new-secret)
6. [Troubleshooting](#troubleshooting)

## How it works

```
Terraform (modules/secrets, modules/rds)  ->  AWS Secrets Manager  petclinic/{env}/...
                                                      ^  read-only, IRSA role petclinic-{env}-eso-role
ClusterSecretStore aws-secrets-manager  --jwt-->  ServiceAccount external-secrets-sa (external-secrets)
                                                      |
ExternalSecret (namespace petclinic-{env})  ->  Kubernetes Secret (env vars in the pods)
```

| Piece | Where | Notes |
|-------|-------|-------|
| Secrets | `terraform/modules/secrets/`, `terraform/modules/rds/` | RDS credentials come from the RDS module only |
| IRSA role | `petclinic-{env}-eso-role` | Reads only `petclinic/{env}/*`; trusts only `external-secrets:external-secrets-sa` |
| ESO | Release `v2.14.0`, namespace `external-secrets` | Installed with `kubectl apply --server-side` by `scripts/install-eso.sh` |
| Store | `k8s/base/external-secrets/cluster-secret-store.yaml` | `ClusterSecretStore`, API `external-secrets.io/v1` (`v1beta1` is not served by ESO v2.14.0) |
| ExternalSecrets | `k8s/base/external-secrets/{rds-credentials,openai-api-key}.yaml` | Refresh every 1h |

## Install ESO

Prerequisites: EKS cluster running, `kubectl` pointed at `petclinic-{env}`, and the secrets module applied so the `eso_role_arn` output exists.

1. Set the OpenAI key without writing it to a file, then plan and apply:
   ```bash
   export TF_VAR_openai_api_key="<your OpenAI API key>"
   cd terraform/environments/{env} && terraform plan -out plan.out
   terraform apply plan.out
   ```
2. Check the install, then install it (run from the repo root):
   ```bash
   ./scripts/install-eso.sh {env}
   ./scripts/install-eso.sh {env} --apply
   ```
3. Verify:
   ```bash
   kubectl -n external-secrets get pods
   kubectl get clustersecretstore aws-secrets-manager
   ```
   Expected: 3 pods Running (`external-secrets`, `external-secrets-webhook`, `external-secrets-cert-controller`) and the store `STATUS` is `Valid`, `READY` is `True`.

## Sync the application secrets

Needs the namespace `petclinic-{env}` to exist.

```bash
kubectl create ns petclinic-dev
kubectl apply -f k8s/base/external-secrets/rds-credentials.yaml -f k8s/base/external-secrets/openai-api-key.yaml
kubectl get externalsecret,secret -n petclinic-dev
```

The manifests hold the dev values (namespace `petclinic-dev`, secrets `petclinic/dev/...`). For prod, copy each file and change the namespace and the `remoteRef.key`. `scripts/apply-external-secrets.sh` is an optional helper that does the same with placeholders.

Expected: `rds-credentials` (keys `username`, `password`) and `openai-api-key` (key `OPENAI_API_KEY`) show `SecretSynced` and `Ready`.

## Test with a sample ExternalSecret

Use this to prove the whole chain without touching the real secrets. It reads the existing OpenAI secret into a throwaway Kubernetes Secret.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: eso-smoke-test
  namespace: petclinic-{env}
  labels:
    app.kubernetes.io/name: eso-smoke-test
    app.kubernetes.io/part-of: petclinic
    app.kubernetes.io/managed-by: kubectl
    app.kubernetes.io/component: infrastructure
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: eso-smoke-test
  data:
    - secretKey: value
      remoteRef:
        key: petclinic/{env}/openai-api-key
EOF
kubectl get externalsecret eso-smoke-test -n petclinic-{env}
kubectl get secret eso-smoke-test -n petclinic-{env}
```

Clean up (this removes the test Secret too, because ESO owns it):

```bash
kubectl delete externalsecret eso-smoke-test -n petclinic-{env}
```

Never print the secret value (`kubectl get secret -o yaml` or `jq`) into a chat, ticket or log.

## Add a new secret

1. **Create the secret in Terraform** (`terraform/modules/secrets/main.tf`): an `aws_secretsmanager_secret` named `${local.secret_prefix}/<name>` plus an `aws_secretsmanager_secret_version`. Take the value from a `sensitive = true` variable, never from code. Add an output with the ARN.
2. **Pass the value** with `TF_VAR_<name>` or the git-ignored `terraform.tfvars`, then plan and apply.
3. **Add an ExternalSecret** in `k8s/base/external-secrets/<name>.yaml`. Copy `openai-api-key.yaml` (plaintext secret) or `rds-credentials.yaml` (JSON secret with `remoteRef.property`). Keep the required labels, the explicit namespace and the `petclinic/${ENV}/<name>` key.
4. **Apply it** (add the file name to the loop in `scripts/apply-external-secrets.sh`) and check `kubectl get externalsecret -n petclinic-{env}`.
5. **Use it in a pod** with `valueFrom.secretKeyRef` (environment variable), not as a mounted file.

The ESO policy only allows names under `petclinic/{env}/`. A secret outside that path is invisible to ESO.

**State and rotation:** Terraform writes the secret value to the state file (`petclinic/{env}/terraform.tfstate`). The state bucket is encrypted and private; keep read access limited to the people who deploy. To rotate the OpenAI key, set the new `TF_VAR_openai_api_key`, then plan and apply; ESO picks it up within 1h (or force a sync, see Troubleshooting).

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| ClusterSecretStore `InvalidProviderConfig` or `AccessDenied` | ServiceAccount annotation missing, or the role trust does not match | `kubectl -n external-secrets get sa external-secrets-sa -o yaml` shows `eks.amazonaws.com/role-arn`; compare with `terraform output eso_role_arn` |
| ClusterSecretStore `InvalidProviderConfig`, log says `Token audience contains more than one audience` | `audiences` set on the `serviceAccountRef`; ESO already requests `sts.amazonaws.com`, so the token carries it twice | Remove `audiences` from `cluster-secret-store.yaml` and re-apply |
| ExternalSecret `SecretSyncedError`, secret not found | Secret does not exist yet or wrong name | `aws secretsmanager list-secrets --region us-east-1 --query 'SecretList[].Name'` must list `petclinic/{env}/...` |
| `no matches for kind ... external-secrets.io/v1beta1` | Old API version in a manifest | Use `external-secrets.io/v1` |
| Webhook error when applying a store | ESO pods not ready yet | Wait for `kubectl -n external-secrets rollout status deploy/external-secrets-webhook` |
| Secret did not update after a change | Refresh interval is 1h | `kubectl annotate externalsecret <name> -n petclinic-{env} force-sync=$(date +%s) --overwrite` |
