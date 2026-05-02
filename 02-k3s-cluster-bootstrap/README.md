# Chapter 02 — K3s Cluster Bootstrap

## Architecture Decision

**3-node embedded etcd HA** — 2 x86 nodes + Pi 5 16GB as the third server.

- etcd needs an odd quorum of ≥ 3 nodes. 2 x86 alone can't form quorum.
- Pi 5 16GB is the strongest ARM candidate — etcd is lightweight in read-heavy homelab workloads.
- Survives loss of any single server node without cluster downtime.
- All 6 nodes schedule workloads (no taints — server nodes run pods too).
- Probably need to be careful with Sd card and etcd [documentation](https://docs.k3s.io/datastore/ha-embedded)
## Cluster Roles

| Node | IP | Arch | Role |
|---|---|---|---|
| node01 | 192.168.0.104 | x86_64 | k3s server — first (cluster-init, etcd bootstrap) |
| node02 | 192.168.0.105 | x86_64 | k3s server — second |
| pi-node02 | 192.168.0.202 | arm64 | k3s server — third (etcd member) |
| pi-node01 | 192.168.0.201 | arm64 | k3s agent |
| pi-node03 | 192.168.0.203 | arm64 | k3s agent |
| pi-node04 | 192.168.0.204 | arm64 | k3s agent |

## Default Component Decisions

| Component | Kept? | Notes |
|---|---|---|
| Flannel (VXLAN) | Yes | CNI — handles pod networking |
| CoreDNS | Yes | In-cluster DNS |
| Traefik | **Disabled** | NPM handles ingress externally for now |
| Klipper ServiceLB | **Disabled** | MetalLB handles LoadBalancer IPs  |
| Local-path provisioner | Default off | NFS StorageClasses used instead |

---

## Ansible Automation (Recommended)

Uses [k3s-io/k3s-ansible](https://github.com/k3s-io/k3s-ansible) as a git submodule inside `homelab-ansible/vendor/k3s-ansible/`. All configuration lives outside the submodule in the `homelab-ansible/` directory.

### One-time setup

```bash
cd homelab-ansible

# 1. Install collection dependencies
ansible-galaxy collection install -r requirements.yml

# 2. Set the cluster token in group_vars/k3s_cluster.yml
#    Generate one:
openssl rand -base64 64 | tr -d '\n'
#    Then paste it as the 'token' value in group_vars/k3s_cluster.yml

# 3. Run
ansible-playbook playbooks/k3s/site.yml --ask-pass --ask-become-pass
```

### Playbook structure

```
homelab-ansible/
├── vendor/k3s-ansible/          ← git submodule (upstream, don't edit)
├── inventory/
│   ├── hosts.yml
│   └── group_vars/
│       └── k3s_cluster.yml      ← all k3s config (version, token, flags)
└── playbooks/k3s/
    ├── site.yml                 ← pre-flight + k3s-ansible install + labels
    ├── upgrade.yml              ← wrapper → k3s-ansible upgrade
    ├── reset.yml                ← wrapper → k3s-ansible reset (destructive)
    └── labels.yml               ← custom node-role.homelab labels
```

### What runs

**`site.yml`** does three things in order:
1. **Homelab pre-flight** (our additions): installs `nfs-common`, `open-iscsi` (x86), disables swap
2. **k3s-ansible `site.yml`**: handles kernel modules, sysctl, Pi cgroup cmdline fix + reboot, k3s server/agent install (sequential HA bootstrap), kubeconfig fetch to `~/.kube/config`
3. **`labels.yml`**: applies `node-role.homelab/server` and `worker` labels

**`upgrade.yml`** — upgrades k3s to the version in `group_vars/k3s_cluster.yml`, servers serial (etcd safety), agents parallel.

**`reset.yml`** — tears down the cluster. Destructive, use with care.

### Key configuration (`inventory/group_vars/k3s_cluster.yml`)

| Variable | Purpose |
|---|---|
| `k3s_version` | Pinned k3s release (e.g. `v1.31.3+k3s1`) |
| `token` | Shared cluster secret — set before first run |
| `api_endpoint` | First server IP (`192.168.0.104`) |
| `extra_server_args` | `--disable traefik --disable servicelb` |
| `server_config_yaml` | Per-node config: `node-ip`, `tls-san`, `flannel-backend` |
| `agent_config_yaml` | Per-agent config: `node-ip` |

### Docker coexistence on node01

node01 runs Docker containers (Portainer + docker-compose stacks). k3s installation is safe:

- **No reboot** triggered on x86 — the cgroup cmdline change is ARM-only
- k3s uses its own bundled containerd at `/var/lib/rancher/k3s/agent/containerd/` — completely separate from Docker
- sysctl params (`ip_forward`, `bridge-nf-call-iptables`) are already set by Docker — reapplying is a no-op
- Flannel creates a `flannel.1` VXLAN interface — does not touch Docker's `docker0` bridge

**One known risk:** After Flannel installs, it modifies iptables FORWARD rules. In rare cases this can disrupt Docker port mappings. The install playbook prints a Docker container count before and after install. If port-mapped containers lose connectivity, run on node01:

```bash
iptables -P FORWARD ACCEPT
```

---

## Manual Steps Reference

> The Ansible playbooks above automate everything below. These steps are kept as reference for understanding or manual recovery.

### Phase 1 — OS Pre-Flight (All Nodes)

#### 1.1 Hostnames + Static IPs

```bash
hostnamectl set-hostname <chosen-hostname>
```

Assign static IPs via router DHCP reservations. Ensure all nodes can resolve each other by hostname (router local DNS preferred, or `/etc/hosts` fallback).

#### 1.2 OS Packages

All nodes:
```bash
apt-get update && apt-get upgrade -y
apt-get install -y nfs-common curl
```

x86 nodes additionally:
```bash
apt-get install -y open-iscsi
```

#### 1.3 cgroup Fix — ARM Pis ONLY (k3s will fail without this)

Edit `/boot/firmware/cmdline.txt` — append to the **single existing line** (no newline):

```
cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory
```

Reboot, then verify:
```bash
cat /proc/cgroups | grep memory
# "enabled" column must show 1
```

#### 1.4 Disable Swap (All Nodes)

```bash
swapoff -a
# Comment out or remove swap entry in /etc/fstab
```

#### 1.5 Kernel Modules and sysctl (All Nodes)

```bash
modprobe br_netfilter overlay
echo -e "br_netfilter\noverlay" > /etc/modules-load.d/k3s.conf
cat > /etc/sysctl.d/99-k3s.conf <<EOF
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sysctl --system
```

#### 1.6 Firewall Ports (Between All Cluster Nodes)

| Port | Proto | Purpose |
|---|---|---|
| 6443 | TCP | k3s API server |
| 2379–2380 | TCP | etcd peer communication (server nodes only) |
| 8472 | UDP | Flannel VXLAN overlay |
| 10250 | TCP | kubelet metrics |

NFS: port 2049 TCP/UDP open from all cluster nodes → `<NAS_IP>` and `<SERVER_A_IP>`.

### Phase 2 — k3s Install (Sequential)

#### 2.1 First Server — Bootstrap etcd (node01)

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --cluster-init \
  --disable traefik \
  --disable servicelb \
  --node-ip 192.168.0.104 \
  --tls-san 192.168.0.104 \
  --tls-san 192.168.0.105 \
  --tls-san 192.168.0.202 \
  --flannel-backend vxlan" sh -
```

Wait for ready:
```bash
kubectl get nodes
```

Save the cluster token:
```bash
cat /var/lib/rancher/k3s/server/node-token
```

#### 2.2 Second Server (node02)

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --server https://192.168.0.104:6443 \
  --token <CLUSTER_TOKEN> \
  --disable traefik \
  --disable servicelb \
  --node-ip 192.168.0.105 \
  --flannel-backend vxlan" sh -
```

#### 2.3 Third Server (pi-node02)

Same as 2.2, substituting `--node-ip 192.168.0.202`.

Verify etcd quorum after all 3 servers are up:
```bash
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/k3s/server/tls/etcd/server-client.crt \
  --key=/var/lib/rancher/k3s/server/tls/etcd/server-client.key \
  member list
# Must show 3 members, all healthy
```

#### 2.4 Agent Nodes (pi-node01, pi-node03, pi-node04)

Run on each agent — substitute `<THIS_NODE_IP>`:
```bash
curl -sfL https://get.k3s.io | K3S_URL=https://192.168.0.104:6443 \
  K3S_TOKEN=<CLUSTER_TOKEN> \
  INSTALL_K3S_EXEC="agent --node-ip <THIS_NODE_IP>" sh -
```

#### 2.5 Configure kubectl on Your Workstation

```bash
scp venom@192.168.0.104:/etc/rancher/k3s/k3s.yaml ~/.kube/config
# Edit ~/.kube/config: replace 127.0.0.1 with 192.168.0.104
kubectl get nodes -o wide
# Expect: 6 nodes, all Ready
```

### Phase 3 — Node Labels

```bash
kubectl label node node01    node-role.homelab/server=true
kubectl label node node02    node-role.homelab/server=true
kubectl label node pi-node02 node-role.homelab/server=true
kubectl label node pi-node01 node-role.homelab/worker=true
kubectl label node pi-node03 node-role.homelab/worker=true
kubectl label node pi-node04 node-role.homelab/worker=true
```

`kubernetes.io/arch` (`amd64`/`arm64`) is auto-applied by k3s. To pin a workload to a specific arch:
```yaml
nodeSelector:
  kubernetes.io/arch: amd64   # or arm64
```

---

## Verification

```
[ ] kubectl get nodes -o wide       → 6 nodes, all Ready
[ ] kubectl get pods -A             → no CrashLoopBackOff
[ ] etcdctl member list             → 3 members, all healthy
[ ] kubectl run test --image=nginx --restart=Never  → pod reaches Running
[ ] docker ps (on node01)           → all containers still running
```

## HA API Access — Current Limitation

All three server nodes (192.168.0.104, 192.168.0.105, 192.168.0.202) run their own kube-apiserver, and the TLS certificate covers all three via `tls-san`. Any of them accepts `kubectl` connections.

However, the kubeconfig and agent `api_endpoint` are both pinned to `192.168.0.104`. If that node goes down:
- `kubectl` from your workstation stops working
- Agents lose their API connection (etcd quorum is maintained with the remaining 2 nodes, so the cluster keeps running, but no new workloads are scheduled)

**The fix: kube-vip** — runs as a DaemonSet on server nodes and moves a Virtual IP (VIP) between them. Both the kubeconfig and `api_endpoint` then point to the VIP instead of any single node, giving transparent API failover.

This is covered in **Chapter 09 — kube-vip**.

## Known Limitations

### pi-node02 — SD card as etcd member

pi-node02 (the third etcd server) runs on SD card. k3s docs note that SD cards struggle with etcd write I/O. In practice this is acceptable for a homelab:
- etcd traffic is KB/s-range in read-heavy workloads
- The two x86 SSD nodes carry primary etcd load
- SD card failure loses the minority etcd member — cluster remains operational

Monitor with `etcdctl endpoint status` if latency issues appear.
