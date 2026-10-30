# RDS Database Initialization Strategy (PETPLAT-24)

## Decision: Spring Boot auto-initialization

Terraform creates the empty shared `petclinic` database (`db_name` on the RDS instance).
Each database-backed service creates its own tables on first startup:

- Active profiles: `docker,mysql`
- `spring.sql.init.mode=always` (runs `schema.sql` and `data.sql` from `src/main/resources/db/mysql/`)

No manual SQL, no init container, no Terraform provisioner.

## One shared database

customers, visits and vets all use the single `petclinic` database.
The cross-service foreign key `visits.pet_id` -> `pets.id` requires this.

## Schema scripts (7 tables)

| Order | Service | Tables |
|-------|---------|--------|
| 1 | customers-service | `types`, `owners`, `pets` |
| 2 | vets-service | `vets`, `specialties`, `vet_specialties` (independent) |
| 3 | visits-service | `visits` (FK to `pets`) |

Order is enforced by deploying customers-service before visits-service
(ArgoCD sync waves or init containers; visits must not start before `pets` exists).

## Connection string (K8s ConfigMap)

```
SPRING_DATASOURCE_URL=jdbc:mysql://<rds_endpoint>:3306/petclinic
```

`<rds_endpoint>` is the `rds_endpoint` Terraform output (no port).
Username and password are NOT in ConfigMaps. They come from the `rds-credentials`
Kubernetes Secret, synced by External Secrets Operator from Secrets Manager
`petclinic/{env}/rds-credentials` (keys `username`, `password`), mapped to
`SPRING_DATASOURCE_USERNAME` / `SPRING_DATASOURCE_PASSWORD`.

## Verification (PETPLAT-26, after deploy)

```bash
kubectl run mysql-debug -n petclinic-dev --rm -it --image=mysql:8.4 --restart=Never -- \
  mysql -h <rds_endpoint> -u petclinic -p -e "USE petclinic; SHOW TABLES;"
```

Expect 7 tables once all three services have started once.
