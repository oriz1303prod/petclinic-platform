# EKS module

Cluster, node group, OIDC provider (IRSA), kubectl access and managed add-ons for `petclinic-{env}`.
Spec: `docs/technical-spec.md` (EKS Cluster, IRSA Roles). Stories: PETPLAT-12, 13, 14, 84.

## kubectl access

The principal that runs `terraform apply` becomes cluster-admin automatically
(`bootstrap_cluster_creator_admin_permissions`). After apply:

```bash
eval "$(terraform output -raw eks_kubeconfig_command)"
kubectl get nodes
```

### Add another user or role

Add an entry to `access_entries` in the environment's `main.tf` (`terraform/environments/{env}/main.tf`), then plan and apply:

```hcl
module "eks" {
  # ...
  access_entries = {
    platform-admins = {
      principal_arn = "arn:aws:iam::<account-id>:role/<role-name>"
      policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
    }
  }
}
```

Default policy is `AmazonEKSViewPolicy` (read-only). For SSO roles use the IAM role ARN without the
`aws-reserved/sso.amazonaws.com/<region>/` path segment.
Policy ARNs: `aws eks list-access-policies --region us-east-1`.

## Upgrading add-on versions

Versions are pinned in `addon_versions` (never `latest`). To upgrade:

1. List compatible versions (mark `defaultVersion=true` as the recommended one):
   ```bash
   aws eks describe-addon-versions --addon-name coredns --kubernetes-version 1.35 --region us-east-1 \
     --query 'addons[0].addonVersions[].[addonVersion,compatibilities[0].defaultVersion]' --output table
   ```
   Repeat for `kube-proxy`, `vpc-cni`, `aws-ebs-csi-driver`.
2. Read the add-on release notes, then change the version in `addon_versions` (module default or override in `main.tf`).
3. Apply dev first: `terraform plan -out plan.out`, review, `terraform apply plan.out`; verify `kubectl get pods -n kube-system`.
4. Repeat for prod.

Conflict strategy is `OVERWRITE` (initial setup). Switch `addon_resolve_conflicts` to `PRESERVE` once you
customize add-on configuration in-cluster.

## Notes

- The OIDC provider thumbprint comes from the `hashicorp/tls` provider (`tls_certificate`); AWS ignores it for EKS issuers, and plan needs internet access to the issuer.
- Nodes use a launch template: node SG attached, encrypted gp3 root volume, IMDSv2 required.
- API endpoint is public and private; `endpoint_public_access_cidrs` is required (no `0.0.0.0/0`).
- Kubernetes secrets are envelope-encrypted with a module-created KMS key (rotation on). It cannot be disabled once enabled.
- `bootstrap_cluster_creator_admin` (default true) gives the apply principal permanent admin. For prod, set it to false and grant a role through `access_entries`.
- `desired_size` is managed by Terraform (no autoscaler on this node group); change `node_desired_size` to scale.
- `upgrade_policy = STANDARD` avoids automatic paid extended support; plan a version upgrade before standard support ends.
- Capacity is `ON_DEMAND` (the Graviton free trial does not cover Spot).
