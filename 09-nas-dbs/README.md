# Chapter 09 — DBs in Homelab (NAS-hosted)

## Why not in-cluster

The NAS is already the single point of failure — all PVCs are NFS-backed. If the NAS goes down, the cluster loses storage anyway. Running DBs there costs nothing extra in the failure model but removes a lot of complexity.

## Solution

All stateful services run on the NAS as Docker Compose. k8s apps connect via headless Services pointing to the NAS IP.

```
k8s apps
   │   (nas-postgres:5432, nas-mariadb:3306, nas-redis:6379)
   ▼
NAS — Docker Compose
  pgbouncer :5432 → postgres :5432
  proxysql  :3306 → mariadb  :3306
  redis     :6379
  dbgate    :8090  ← unified web UI
```

Apps always go through the pooler. Direct ports (5433, 3307) are for admin/migrations only.

---

## Services

| Service | Image | Port (host) |
|---|---|---|
| postgres | `pgvector/pgvector:0.8.2-pg18-trixie` | 5433 (admin) |
| pgbouncer | `edoburu/pgbouncer:v1.25.1-p0` | **5432** (apps) |
| mariadb | `mariadb:11.8.6-noble` | 3307 (admin) |
| proxysql | `proxysql/proxysql:3.0.8` | **3306** (apps), 6032 (admin) |
| redis | `redis:8.6.2-alpine` | **6379** |
| dbgate | `dbgate/dbgate:latest` | **8090** |
| postgres-exporter | `ghcr.io/nbari/pg_exporter:latest` | 9432 |
| mysqld-exporter | `prom/mysqld-exporter:v0.16.0` | 9104 |
| redis-exporter | `oliver006/redis_exporter:v1.66.0` | 9121 |

---

## Credentials

> **Temporary credentials are in use.** All passwords are set to `Homelab@123` for now.
> Will be rotated and moved to a proper secrets manager later.

| Service | User | Password | Notes |
|---|---|---|---|
| Postgres | `admin` | `Homelab@123` | plaintext stored in pgbouncer userlist.txt |
| MariaDB | `root` | `Homelab@123` | |
| Redis | — | `Homelab@123` | requirepass |
| ProxySQL admin | `admin` | `Homelab@123` | port 6032 |
| DBgate | — | — | no auth, LAN only |

Credentials live in `.env` on the NAS at `/mnt/ssd_mirror/docker_mounts/cluster_dbs/.env`.
The `.env.example` in the repo has the current values filled in.

---

## Metrics

Each DB has a sidecar exporter. Prometheus (in-cluster) scrapes NAS directly via static targets.

| Exporter | Endpoint | Scrapes |
|---|---|---|
| postgres-exporter | `NAS_IP:9432/metrics` | PostgreSQL direct (not pgbouncer) |
| mysqld-exporter | `NAS_IP:9104/metrics` | MariaDB as root |
| redis-exporter | `NAS_IP:9121/metrics` | Redis |

Scrape config: `homelab-argo/values/prom-stack/values.yaml` → `prometheusSpec.additionalScrapeConfigs`.

---

## Some Notes on the Setup

### pgvector image for Postgres

Using `pgvector/pgvector` instead of plain `postgres:18`. Includes pgvector + all contrib extensions pre-compiled. Can `CREATE EXTENSION vector`, `uuid-ossp`, `pg_trgm`, `pgcrypto`, `citext`, etc. without touching the image. Plain `postgres:18` doesn't have pgvector.

### PG18 volume layout

PostgreSQL 18 changed the data directory layout. The mount must be at `/var/lib/postgresql` (not `/var/lib/postgresql/data`). PG18 creates a versioned subdirectory (`18/docker/`) inside it. Old-style mounts at `/data` will cause the container to refuse to start.

### PgBouncer in session mode

`pool_mode = session` — a client holds the same backend connection for its entire session. Transaction mode (`transaction`) is more efficient but breaks prepared statements, which Grafana and most ORM-based apps use extensively. Stick with session mode unless you know an app is prepared-statement-free.

### PgBouncer userlist.txt must use plaintext passwords

PostgreSQL 18 defaults to `scram-sha-256` in `pg_hba.conf`. PgBouncer needs the plaintext password to perform the SCRAM handshake with the backend — an md5 hash is not enough. All entries in `userlist.txt` must be `"username" "plaintext_password"`. The `create-pg-db.sh` script handles this automatically.

### Why ProxySQL and not MaxScale

MaxScale 25.x needs a license. ProxySQL is open source and handles single-node MariaDB fine. MariaDB also handles connections much better than Postgres (threads vs processes), so connection pooling here is less critical — but keeps apps off direct root connections.

### pgbouncer.ini — database entries must stay in [databases]

The `create-pg-db.sh` script inserts new DB entries before the `[pgbouncer]` section header using `sed`. Never append to the end of the file — pgbouncer reads the file top-to-bottom and assigns keys to whichever section header was last seen. An entry after `[pgbouncer]` becomes a `[pgbouncer]` parameter and crashes on startup with `unknown parameter`.

### ProxySQL loads from its DB, not the config file

Once ProxySQL has started once, it writes a `proxysql.db` in its data dir and ignores the config file on subsequent starts. To reset to config file: delete `proxysql/data/proxysql.db` and restart.

### DBgate connections are added manually

The env var approach (`CONNECTIONS__id__engine`) doesn't work in DBgate 7.x when the container runs via Docker Compose on TrueNAS. Connections are added once through the UI at `http://NAS_IP:8090` and persisted in the dbgate volume. Add:
- Postgres → host `postgres`, port `5432`, user `admin`
- MariaDB → host `mariadb`, port `3306`, user `root`
- Redis → host `redis`, port `6379`, password from `.env`

### MariaDB root and IPv6

Docker's internal network resolves container names to IPv6 addresses. MariaDB's `root@'%'` wildcard doesn't cover IPv6 connections by default. After first start, run:

```bash
docker exec -it cluster_dbs-mariadb-1 mariadb -u root -pPASSWORD
```
```sql
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
```

### Healthchecks

- Postgres: `pg_isready -U admin -d postgres` — must specify `-d postgres`, otherwise pg_isready tries to connect to a DB named after the user which doesn't exist.
- MariaDB: `healthcheck.sh --su-mysql --connect --innodb_initialized` — official script from the image, connects via unix socket as mysql user, no password needed.
- Redis: `redis-cli -a $REDIS_PASSWORD ping` — straightforward.

---

## PostgreSQL Extensions

Extensions available in the pgvector image — run `CREATE EXTENSION IF NOT EXISTS x;` per database, no image rebuild needed:

```sql
CREATE EXTENSION IF NOT EXISTS vector;          -- pgvector
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS hstore;
```

**Need an extension not in the image** (e.g. PostGIS)? Add a `Dockerfile` next to compose:

```dockerfile
FROM pgvector/pgvector:0.8.2-pg18-trixie
RUN apt-get update && apt-get install -y postgresql-18-postgis-3 \
 && rm -rf /var/lib/apt/lists/*
```

Swap `image:` for `build:` in compose, then `docker compose build postgres && docker compose up -d postgres`. Data is preserved.

---

## Creating New Databases

### Postgres

```bash
./scripts/create-pg-db.sh <dbname> <username> <password>
```

Does everything in one shot: creates DB + user in Postgres (scram-sha-256), inserts into `pgbouncer.ini` under `[databases]`, appends plaintext password to `userlist.txt`, sends `SIGHUP` to pgbouncer (zero-downtime reload).

### MariaDB

```bash
./scripts/create-mysql-db.sh <dbname> <username> <password>
```

Creates DB + user in MariaDB, registers user in ProxySQL via its admin interface.

---

## Kubernetes Services

All three services live in the shared `nas-services` namespace, managed by the `nas-externalsvc` ArgoCD app (`homelab-argo/argocd/apps/nas-externalsvc.yaml`). Apps in other namespaces reference them by FQDN: `nas-postgres.nas-services.svc.cluster.local`.

**Do not use `ExternalName` services with a raw IP address.** CoreDNS returns a CNAME record, and CNAME targets must be hostnames — DNS clients won't follow a CNAME pointing to an IP. Instead, use a headless Service + Endpoints:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nas-postgres
  namespace: nas-services
spec:
  clusterIP: None
  ports:
    - port: 5432
      targetPort: 5432
---
apiVersion: v1
kind: Endpoints
metadata:
  name: nas-postgres
  namespace: nas-services
subsets:
  - addresses:
      - ip: 192.168.0.180
    ports:
      - port: 5432
```

This gives a real DNS A record → `192.168.0.180` rather than a broken CNAME.

---

## Files

Everything lives in `nas-services/cluster-dbs/` in this repo. Copy the folder to the NAS, fill in `.env`, run `docker compose up -d`.

```
nas-services/cluster-dbs/
├── docker-compose.yml
├── .env.example
├── postgres/init/00-extensions.sql
├── pgbouncer/pgbouncer.ini
├── pgbouncer/userlist.txt
├── proxysql/proxysql.cnf
└── scripts/
    ├── create-pg-db.sh
    └── create-mysql-db.sh
```

---

## Access

| | |
|---|---|
| DBgate | `http://192.168.0.180:8090` |
| Postgres (apps) | `192.168.0.180:5432` |
| Postgres (admin) | `192.168.0.180:5433` |
| MariaDB (apps) | `192.168.0.180:3306` |
| MariaDB (admin) | `192.168.0.180:3307` |
| ProxySQL admin | `mysql -h 192.168.0.180 -P 6032 -u admin -p` |
| Redis | `192.168.0.180:6379` + password |
