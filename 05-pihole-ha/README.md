# Pi-hole HA

Pi-hole + Unbound on all 7 hosts with keepalived VRRP failover. Two stable DNS VIPs for the whole home network. Unbound handles recursive DNS resolution — no forwarding to 1.1.1.1 or 8.8.8.8.

## Architecture

```
DNS1 → 192.168.0.251  (master: truenas, fallback: node01 → node02 → ...)
DNS2 → 192.168.0.252  (master: node02, fallback: node01 → pi-node02 → ...)

Per node: unbound (127.0.0.1:5335) → pihole (:53, :25080) → keepalived (VRRP) → pihole-exporter (:9617)
Sync: nebula-sync on truenas → pushes to all 6 cluster nodes hourly
```

Failover takes ~4s. TrueNAS owns VIP1 when up.

## Files

All configs live in [`homelab-ansible/playbooks/pihole-ha/`](../homelab-ansible/playbooks/pihole-ha/).

| File | Purpose |
|---|---|
| [`preflight.yml`](../homelab-ansible/playbooks/pihole-ha/preflight.yml) | Pre-deploy checks + setup (systemd-resolved, docker, ports) |
| [`deploy.yml`](../homelab-ansible/playbooks/pihole-ha/deploy.yml) | Deploy stack to all 6 cluster nodes |
| [`docker-compose.yml`](../homelab-ansible/playbooks/pihole-ha/docker-compose.yml) | Stack: unbound + pihole + keepalived + pihole-exporter + nebula-sync |
| [`templates/keepalived.conf.j2`](../homelab-ansible/playbooks/pihole-ha/templates/keepalived.conf.j2) | VRRP config (per-node priorities) |
| [`templates/node.env.j2`](../homelab-ansible/playbooks/pihole-ha/templates/node.env.j2) | Runtime env for docker compose |
| [`files/unbound.conf`](../homelab-ansible/playbooks/pihole-ha/files/unbound.conf) | Recursive resolver config (listens on 127.0.0.1:5335) |
| [`files/check_pihole.sh`](../homelab-ansible/playbooks/pihole-ha/files/check_pihole.sh) | Keepalived health check (port 53) |
| [`files/keepalived.conf.truenas`](../homelab-ansible/playbooks/pihole-ha/files/keepalived.conf.truenas) | Static keepalived config for TrueNAS (manual) |
| `.env.example` | Copy to `.env`, set pihole_password |

## Deploy — Cluster Nodes (Ansible)

```bash
cd homelab-ansible/playbooks/pihole-ha
cp .env.example .env
# edit .env — set pihole_password

cd ../..

# Step 1: preflight (disables systemd-resolved, installs docker, checks ports)
ansible-playbook playbooks/pihole-ha/preflight.yml

# Step 2: deploy
ansible-playbook playbooks/pihole-ha/deploy.yml
```

## Deploy — TrueNAS (Manual via Portainer)

TrueNAS is not in the Ansible inventory, deploy manually.

**1. Find your interface name on TrueNAS:**
```bash
ip route | awk '/default/{print $5}'
```

**2. Edit `files/keepalived.conf.truenas`** — replace both `REPLACE_WITH_IFACE` with the actual interface name.

**3. Check port 53 is free on TrueNAS** — TrueNAS SCALE may have its own DNS service. Disable it in **System → Services** if needed.

**4. Place files on TrueNAS:**
```bash
mkdir -p /mnt/ssd_mirror/docker_mounts/pihole-ha/keepalived /mnt/ssd_mirror/docker_mounts/pihole-ha/unbound /mnt/ssd_mirror/docker_mounts/pihole-ha/data/pihole
```

| Source (this repo) | Destination on TrueNAS |
|---|---|
| `playbooks/pihole-ha/docker-compose.yml` | `/mnt/ssd_mirror/docker_mounts/pihole-ha/docker-compose.yml` |
| `playbooks/pihole-ha/files/keepalived.conf.truenas` | `/mnt/ssd_mirror/docker_mounts/pihole-ha/keepalived/keepalived.conf` |
| `playbooks/pihole-ha/files/check_pihole.sh` | `/mnt/ssd_mirror/docker_mounts/pihole-ha/keepalived/check_pihole.sh` |
| `playbooks/pihole-ha/files/unbound.conf` | `/mnt/ssd_mirror/docker_mounts/pihole-ha/unbound/unbound.conf` |

**5. Create `.env` on TrueNAS** (KEY=VALUE format, not YAML):
```bash
cat > /mnt/ssd_mirror/docker_mounts/pihole-ha/.env <<EOF
PIHOLE_PASSWORD=yourpassword
TZ=Asia/Kolkata
EOF
chmod 600 /mnt/ssd_mirror/docker_mounts/pihole-ha/.env
chmod +x /mnt/ssd_mirror/docker_mounts/pihole-ha/keepalived/check_pihole.sh
```

**6. Deploy:**
```bash
cd /mnt/ssd_mirror/docker_mounts/pihole-ha
COMPOSE_PROFILES=primary docker compose up -d
```

## After deploy

Set router DHCP:
- DNS1: `192.168.0.251`
- DNS2: `192.168.0.252`

Admin UI: `http://<any-node-ip>:25080/admin`

Metrics (pihole-exporter): `http://<any-node-ip>:9617/metrics` — scrape from Prometheus with:
```yaml
- job_name: pihole
  static_configs:
    - targets: [192.168.0.180:9617, 192.168.0.104:9617, 192.168.0.105:9617, 192.168.0.202:9617, 192.168.0.201:9617, 192.168.0.203:9617, 192.168.0.204:9617]
```

Verify recursive DNS (DNSSEC test):
```bash
dig @192.168.0.251 dnssec.works +dnssec   # should show ad flag
dig @192.168.0.251 fail01.dnssec.works    # should return SERVFAIL
```

## VIP Failover Priorities

| Node | IP | .251 | .252 |
|---|---|---|---|
| truenas | 192.168.0.180 | 160 (master) | 90 |
| node01 | 192.168.0.104 | 150 | 140 |
| node02 | 192.168.0.105 | 140 | 150 (master) |
| pi-node02 | 192.168.0.202 | 130 | 130 |
| pi-node01 | 192.168.0.201 | 120 | 120 |
| pi-node03 | 192.168.0.203 | 110 | 110 |
| pi-node04 | 192.168.0.204 | 100 | 100 |
