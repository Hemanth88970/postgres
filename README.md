# PostgreSQL 18.4 Primary/Replica on K3s (via ArgoCD) — for Odoo 19

This mirrors the same idea as the ERPGAP Docker Compose demo
(https://www.erpgap.com/blog/odoo-19-pg-replication-demo-erpgap), but as
proper Kubernetes manifests deployed through ArgoCD on **k3s**: one
**primary** Postgres 18.4 for writes, one (or more) **replica** Postgres
18.4 for reads, using native streaming replication — no extra tooling
(no Patroni/repmgr) needed for this setup.

## Folder layout

```
argocd/
  postgres-primary.yaml   # ArgoCD Application -> deploys primary/
  postgres-replica.yaml   # ArgoCD Application -> deploys replica/
primary/
  namespace.yaml          # creates the postgres-ha namespace
  secret.yaml              # superuser + replication credentials
  configmap.yaml           # postgresql.conf, pg_hba.conf, replication-user init SQL
  statefulset.yaml          # the primary Postgres pod + PVC
  headless-service.yaml      # stable DNS for the StatefulSet pod
  service.yaml                # ClusterIP "postgres-primary" — point Odoo writes here
replica/
  secret.yaml              # same replication credentials (kept in sync with primary)
  configmap.yaml             # postgresql.conf/pg_hba.conf for standby + the init script as a 2nd ConfigMap
  init-replica.sh             # standalone copy of the bootstrap script, for reference/manual runs
  statefulset.yaml              # initContainer clones the primary, then runs as a hot standby
  headless-service.yaml          # stable DNS for the StatefulSet pod
  service.yaml                     # ClusterIP "postgres-replica" — point Odoo reads here
```

## How replication actually works here

1. **Primary** starts up, `init-replication-user.sql` (from `primary/configmap.yaml`)
   runs once on first boot and creates the `replicator` role plus a physical
   replication slot `replica1_slot`.
2. **Replica**'s `initContainer` (`init-replica.sh`) waits for the primary to
   be reachable, then runs `pg_basebackup -R` to clone the primary's data
   directory and automatically writes `standby.signal` +
   `postgresql.auto.conf` (with `primary_conninfo`). A `.pgpass` file is also
   written so reconnection survives pod restarts.
3. From then on the replica streams WAL continuously from the primary over
   the replication slot — this is real physical streaming replication, not a
   periodic copy.

## Deploy order

1. **Edit the secrets first.** `primary/secret.yaml` and `replica/secret.yaml`
   ship with placeholder base64 values (`ChangeMeSuperUser1!`,
   `ChangeMeReplica1!`). Generate real ones:
   ```bash
   echo -n 'YourRealPassword' | base64
   ```
   and also update the matching password inside
   `primary/configmap.yaml` → `init-replication-user.sql` (it's currently
   hardcoded to match the placeholder — keep both in sync, or better, switch
   to a tool like Sealed Secrets / External Secrets Operator so you're not
   committing plaintext-adjacent secrets to git at all).
2. **Set your real Git repo URL** in `argocd/postgres-primary.yaml` and
   `argocd/postgres-replica.yaml` (`spec.source.repoURL`).
   `storageClassName` in both `statefulset.yaml` files is already set to
   `local-path`, which is k3s's built-in default
   (Rancher local-path-provisioner) — confirm it's actually there with:
   ```bash
   kubectl get storageclass
   ```
   If your k3s cluster uses something else (Longhorn, NFS, etc.), change it
   to match.
3. Apply the namespace once, then let ArgoCD do the rest:
   ```bash
   kubectl apply -f primary/namespace.yaml
   kubectl apply -f argocd/postgres-primary.yaml
   # wait for primary to be Healthy/Synced in ArgoCD, THEN:
   kubectl apply -f argocd/postgres-replica.yaml
   ```
   The replica's initContainer will fail/retry harmlessly if it comes up
   before the primary is ready — it polls with `pg_isready` — but it's
   cleanest to sync primary first.
4. Verify:
   ```bash
   kubectl -n postgres-ha get pods
   kubectl -n postgres-ha exec -it postgres-primary-0 -- psql -U postgres -c "select * from pg_stat_replication;"
   kubectl -n postgres-ha exec -it postgres-replica-0 -- psql -U postgres -c "select pg_is_in_recovery();"
   ```
   `pg_stat_replication` on the primary should show one row for the replica;
   `pg_is_in_recovery()` on the replica should return `t`.

## Pointing Odoo 19 at it

Odoo 19 has native primary/replica routing — same mechanism the blog post
walks through, just with Kubernetes service names instead of `localhost`
ports. In `odoo.conf`:

```ini
[options]
db_host = postgres-primary.postgres-ha.svc.cluster.local
db_port = 5432
db_user = postgres
db_password = <same password as POSTGRES_PASSWORD>

db_replica_host = postgres-replica.postgres-ha.svc.cluster.local
db_replica_port = 5432
```

- All writes (saving a record, installing a module, etc.) go to
  `postgres-primary`.
- Read-heavy traffic gets routed to `postgres-replica` — and because
  `postgres-replica` is a normal `ClusterIP` Service in front of the
  replica StatefulSet, if you scale `replica/statefulset.yaml` to more than
  1 replica later, Kubernetes load-balances reads across all of them
  automatically — no Odoo config change needed.

To confirm it's actually working, the same way the blog demo does it:
```bash
kubectl -n postgres-ha logs -f postgres-primary-0   # writes should show up here
kubectl -n postgres-ha logs -f postgres-replica-0   # reads should show up here
```

## Notes / things to harden before production

- **Postgres 18 image change**: the official `postgres` image switched its
  default `PGDATA`/`VOLUME` layout in v18+ (now version-specific, e.g.
  `/var/lib/postgresql/18/docker`, with the volume at `/var/lib/postgresql`
  instead of `/var/lib/postgresql/data`). This only matters if you don't set
  `PGDATA` yourself — these manifests already set `PGDATA` explicitly to
  `/var/lib/postgresql/data/pgdata` and mount the PVC at
  `/var/lib/postgresql/data`, so it works the same as it always has. Only
  worry about this if you later upgrade the image tag further (e.g. to v19)
  and run into PGDATA path issues during a `pg_upgrade`.
- **k3s + local-path-provisioner**: `local-path` volumes are host-path based
  and pinned to whichever node the pod first ran on (it uses
  `WaitForFirstConsumer` binding). On a single-node k3s box this is a
  non-issue. On a multi-node k3s cluster, if a pod gets evicted/rescheduled
  to a different node, it'll get stuck `Pending` waiting for its volume. If
  you're running multi-node, consider Longhorn instead for portable storage.
- `pg_hba.conf` on both sides currently allows `0.0.0.0/0` for simplicity —
  tighten this to your actual pod/service CIDR, or use a `NetworkPolicy`.
- This is single-replica, single-primary with **no automatic failover**. If
  the primary pod dies, the StatefulSet will reschedule it and it'll come
  back as primary (data is on the PVC), but there's no automatic promotion
  of the replica. For automatic failover, look at Patroni, repmgr, or a
  managed Postgres operator (CloudNativePG, Zalando's postgres-operator).
- Add `PodDisruptionBudget`s and resource requests/limits tuned to your
  actual workload — the values here are placeholders.
- Consider enabling `archive_mode` + WAL archiving to object storage for
  point-in-time recovery, separate from the replica itself.
