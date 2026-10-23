# DNS with a Cloudflare domain and Route 53 (subdomain delegation)

**Last Updated:** 2026-10-23

**Purpose:** How to use a domain registered at Cloudflare with Route 53, ACM and the AWS Load Balancer
Controller by delegating a subdomain (example: `lab.example.com`) to a Route 53 hosted zone.
Everything after the delegation is the same as in the course. Related: PETPLAT-28 to PETPLAT-32,
module `terraform/modules/dns/`, manifest `k8s/base/ingress/ingress.yaml`.

Cost: hosted zone $0.50/month, ACM certificate free, Cloudflare charges nothing per DNS record.

## Table of Contents

- [What differs from the course](#what-differs-from-the-course)
- [Part 1: Delegate the subdomain (one time)](#part-1-delegate-the-subdomain-one-time)
- [Part 2: Expose the app](#part-2-expose-the-app-after-part-1-the-eks-cluster-must-be-running)
- [Rules](#rules)
- [Troubleshooting](#troubleshooting)

## What differs from the course

| Course | Here |
|--------|------|
| Buy `petclinic-name.click` in Route 53 | Keep the Cloudflare domain; no purchase |
| Route 53 creates the zone and name servers automatically | Terraform creates the zone; you add its 4 name servers as NS records in Cloudflare (one time) |
| `domain_name = "petclinic-name.click"` | `domain_name = "lab.example.com"` (the delegated subdomain) |
| One `terraform apply` | Zone first, delegate, then the rest (certificate validation needs the delegation) |
| App URL `petclinic-dev.<domain>` | `petclinic-dev.lab.example.com` |

## Part 1: Delegate the subdomain (one time)

All commands run in `terraform/environments/dev`.

### 1. Set the domain
In `terraform.tfvars` (not committed; `terraform.tfvars.example` is only a template):
```hcl
domain_name       = "lab.example.com"
create_alb_record = false
```

### 2. Create only the hosted zone
```bash
terraform plan -target=module.dns.aws_route53_zone.this -out plan.out
terraform apply plan.out
terraform output dns_name_servers
```
- The plan must show `1 to add, 0 to change, 0 to destroy` (just the zone).
- Terraform prints a warning that `-target` is in use. That is expected here.
- The output lists 4 name servers, for example:
  ```
  ns-1245.awsdns-27.org
  ns-1707.awsdns-21.co.uk
  ns-189.awsdns-23.com
  ns-828.awsdns-39.net
  ```

### 3. Add the name servers in Cloudflare
Cloudflare dashboard > your domain > **DNS > Records > Add record**, four times:

| Type | Name | Target |
|------|------|--------|
| NS | `lab` | first name server |
| NS | `lab` | second name server |
| NS | `lab` | third name server |
| NS | `lab` | fourth name server |

- Name is only the subdomain label (`lab`), not the full domain.
- Enter targets without the trailing dot. Add all four.
- NS records cannot be proxied, so there is no orange cloud to turn off.

### 4. Check the delegation
```bash
dig NS lab.example.com +short @1.1.1.1
```
It must list the same 4 AWS name servers. If empty, wait a few minutes and retry.
Do not continue until it works.

### 5. Create the rest
```bash
terraform plan -out plan.out
terraform apply plan.out
```
Expected plan: `6 to add, 0 to change, 0 to destroy`:
ACM wildcard certificate (`*.lab.example.com`), its validation record in Route 53, the
certificate validation, and the IAM policy, role and attachment for the AWS Load Balancer Controller.
The certificate is usually issued in 2 to 5 minutes. Check: AWS console > Certificate Manager
(region us-east-1) shows **Issued**.

## Part 2: Expose the app (after Part 1; the EKS cluster must be running)

Run these from the **repo root**, not from the Terraform folder.

### Procedure: Install the AWS Load Balancer Controller (PETPLAT-29)

**When:** after Part 1 step 5 (the IAM role exists) and kubectl points at the cluster.
**Who:** DevOps engineer with AWS access to the cluster.
**Time:** about 2 minutes.

**Steps:**
1. Connect kubectl: `aws eks update-kubeconfig --name petclinic-dev --region us-east-1`
2. Install: `./scripts/install-lb-controller.sh dev`
   (applies the CRDs, adds the `eks` Helm repo, installs chart 3.6.1 in `kube-system`
   with the IRSA role; 1 replica in dev, 2 in prod).

**Verify:**
- `kubectl -n kube-system get deploy aws-load-balancer-controller` shows `1/1`.
- `kubectl get ingressclass alb` exists.
- `kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=20` has no `AccessDenied`.

**Rollback:** `helm uninstall aws-load-balancer-controller -n kube-system`

### Procedure: Create the Ingress and the ALB (PETPLAT-30)

**When:** after the controller is running.
**Who:** DevOps engineer.
**Time:** about 3 minutes.

**Steps:**
1. Create the namespace once: `kubectl create ns petclinic-dev`
2. Add the pod-security labels:
   `kubectl label ns petclinic-dev pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/warn=restricted app.kubernetes.io/part-of=petclinic`
3. Dry run (changes nothing): `./scripts/apply-ingress.sh dev`
4. Create it: `./scripts/apply-ingress.sh dev --apply`

Do not run `kubectl apply -f k8s/base/ingress/` directly: the file contains `${...}` placeholders
that the script fills from Terraform outputs.

**Verify:**
- `kubectl get ingress -n petclinic-dev` shows an ADDRESS (`petclinic-dev-alb-<id>.us-east-1.elb.amazonaws.com`) within about a minute. PORTS shows only 80; HTTPS is set by annotations.
- The ALB `petclinic-dev-alb` appears in the AWS console (EC2 > Load Balancers, us-east-1).

**Rollback:** `kubectl delete ingress api-gateway -n petclinic-dev` (the controller removes the ALB).

### Procedure: Point the domain at the ALB (PETPLAT-31)

**When:** after the Ingress has an ADDRESS.
**Who:** DevOps engineer.
**Time:** about 2 minutes.

**Steps:**
1. In `terraform/environments/dev/terraform.tfvars` set `create_alb_record = true`.
2. `terraform plan -out plan.out` (from `terraform/environments/dev`): expect `1 to add`, the alias record.
3. `terraform apply plan.out`

The course asks you to copy `alb_dns_name` and `alb_hosted_zone_id` by hand. Here the module finds the
ALB by its fixed name (`petclinic-dev-alb`, set in the Ingress annotation), so nothing is copied.
Setting the flag before the ALB exists makes the plan fail.

**Verify:**
- `dig +short petclinic-dev.lab.example.com` returns the ALB IP addresses.
- `curl -I http://petclinic-dev.lab.example.com` returns `301` with `Location: https://...`.
- `curl -I https://petclinic-dev.lab.example.com` returns `503` until a Service named `api-gateway`
  (port 8080) exists in `petclinic-dev`. The 503 comes from the ALB and means DNS, TLS and the load balancer work.
  The app appears automatically after api-gateway is deployed; nothing here needs to change.

**Rollback:** set `create_alb_record = false`, then plan and apply.

### Procedure: Stop paying for the ALB

**When:** at the end of the day or when idle.
**Steps:** `kubectl delete ingress api-gateway -n petclinic-dev` (ALB is about $0.02/hour).
Keep the hosted zone and the Cloudflare records. To recreate, run the Ingress and DNS record steps again.

### Safety checks

- Both scripts stop if the kubectl context is not `petclinic-<env>`
  (fix: `aws eks update-kubeconfig --name petclinic-dev --region us-east-1`).
- The IRSA role trusts only `system:serviceaccount:kube-system:aws-load-balancer-controller`.
  Check: `aws iam get-role --role-name petclinic-dev-lb-controller-role --query 'Role.AssumeRolePolicyDocument'`.

## Rules

- **Keep the hosted zone** through daily rebuilds. A new zone gets new name servers, so the
  Cloudflare records would have to be edited again. The zone has `prevent_destroy`; when idle,
  destroy only `module.eks` and `module.rds`.
- **Never apply everything on a fresh zone.** Certificate validation waits up to 30 minutes for a
  delegation that does not exist yet, then fails.
- A zone deleted within 12 hours of creation is not billed; one kept longer costs the full $0.50.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `dig` returns nothing | Records missing, wrong Name, or still propagating | Check the 4 NS records: Name is `lab`, targets match `terraform output dns_name_servers` |
| Certificate validation times out | Delegation not working | Fix steps 3 and 4, then run `terraform apply` again |
| Plan asks for `domain_name` | Not set in `terraform.tfvars` | Step 1 |
| `terraform destroy` stops at the zone | `prevent_destroy` | Intentional; remove only with approval and expect new name servers |
| No domain at all | | Set `enable_dns = false` (HTTP only on the raw ALB DNS name); remove the `certificate-arn`, `ssl-redirect` and `host` settings from the Ingress |
