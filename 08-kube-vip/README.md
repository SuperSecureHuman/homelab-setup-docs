# Chapter 10 — kube-vip (HA API Endpoint)

## Why kube-vip, not ArgoCD

kube-vip is **k3s infrastructure**, not a workload. It needs to be up before the Kubernetes API server is fully available — that makes it fundamentally different from apps managed by ArgoCD, which depends on the API. Deploy via Ansible alongside k3s, not via `kubectl apply` or ArgoCD.

---

## Problem

3 server nodes run kube-apiserver and etcd. The kubeconfig and agent `api_endpoint` are pinned to a single IP (`192.168.0.104`). If that node goes down, the API becomes unreachable even though the cluster is healthy.

## Solution

kube-vip runs as a **DaemonSet** on each server node. It advertises a shared Virtual IP (VIP) via ARP. One node holds the VIP at a time — if it fails, another takes over within seconds.

| VIP | Purpose |
|---|---|
| `192.168.0.10` | k3s API server (outside DHCP range, confirmed free) |

---

## Key Learnings

### Role split — do not overlap with MetalLB

kube-vip has two modes. Use only one of them:

| Mode | Flag | Use it? |
|---|---|---|
| Control plane HA | `cp_enable: true` | **Yes** — this is kube-vip's job |
| LoadBalancer services | `svc_enable: true` | **No** — MetalLB handles this |

Running `svc_enable: true` alongside MetalLB causes ARP races — both tools try to claim the same service IPs. Keep `svc_enable: false`.

### Interface must be set explicitly per node

`vip_interface: ""` is **not officially supported**. kube-vip does not reliably auto-detect the interface. All three server nodes have different interface names (confirmed via Ansible):

```
node01    (x86_64) → enp1s0
node02    (x86_64) → eno1
pi-node02 (arm64)  → eth0
```

### Why DaemonSet, not static pod

Static pods were tried first and abandoned for two reasons:

1. **No serviceAccountName in static pods** — Kubernetes enforces "mirror pod may not reference service accounts". kube-vip needs RBAC (Lease get/create/update) for leader election. A static pod cannot use a ServiceAccount.

2. **kubeconfig DNS failure** — To work around (1), we tried mounting the k3s kubeconfig (`/etc/rancher/k3s/k3s.yaml`) into the static pod. kube-vip ignored the file and fell back to in-cluster config, which resolves the `kubernetes` hostname via host DNS (1.1.1.1) instead of CoreDNS — and fails. Root cause: `hostNetwork: true` pods use host DNS; the `kubernetes` service DNS name is only resolvable via CoreDNS inside the cluster network.

   There is a workaround: add `127.0.0.1 kubernetes` to `/etc/hosts` on each server node, which makes kube-vip's in-cluster config resolve correctly. This was confirmed working on node01 — the VIP came up and the lease was acquired. But it requires manual /etc/hosts management on every server node, which is not sustainable.

**DaemonSet avoids both problems**: serviceAccountName works, in-cluster config and CoreDNS work normally. No /etc/hosts hacks needed.

### Per-node interface with DaemonSets

A single DaemonSet cannot express different env vars per node. Solution: **one DaemonSet per server node**, each with `nodeSelector: kubernetes.io/hostname` and the correct interface baked in by Ansible using `ansible_facts['default_ipv4']['interface']`.

All three DaemonSets share the same `plndr-cp-lock` Lease and compete for leader election. One pod holds the VIP at a time.

> Use `ansible_facts['default_ipv4']['interface']` — not `ansible_default_ipv4.interface`. The latter is deprecated in ansible-core 2.24+.

### --forks 1 is required

Always run the kube-vip playbook with `--forks 1`. The playbook restarts k3s on server nodes — running restarts in parallel risks simultaneous API downtime across all servers.

---

## Architecture

```
kubectl / k3s agents
        │
        ▼
  192.168.0.10  ← VIP (held by one server at a time)
        │
   ┌────┴──────────────────┐
   │      kube-vip          │  DaemonSet per server node
   └───────────────────────┘
        │          │          │
     node01     node02    pi-node02
     (.104)     (.105)     (.202)
     enp1s0      eno1       eth0

Leader election: plndr-cp-lock Lease in kube-system
```

---

## Deploy via Ansible

Playbook: `homelab-ansible/playbooks/k3s/kube-vip.yml`
Template: `homelab-ansible/playbooks/k3s/templates/kube-vip-daemonset.yaml.j2`

The playbook handles everything in order:
1. Updates `/etc/rancher/k3s/config.yaml` on each server with the VIP in `tls-san`
2. Restarts k3s one node at a time to pick up the new cert SANs
3. Removes any leftover static pod manifests from previous attempts
4. Applies kube-vip RBAC (ServiceAccount + ClusterRole for Lease access)
5. Deploys one DaemonSet per server node (interface auto-detected per node)
6. Waits for all 3 kube-vip pods to be Running
7. Updates `~/.kube/config` on the local workstation to point at the VIP
8. Updates and restarts k3s-agent on all agent nodes

### Check interface names first

```bash
ansible server -m shell \
  -a "ip route get 192.168.0.1 | grep -oP 'dev \K\S+'" \
  --ask-pass
```

> Note: use `ansible server` (inventory group name). Ad-hoc debug with `ansible_default_ipv4` fails because facts are not gathered in ad-hoc mode — use `shell` with `ip route` instead.

### Dry run

```bash
ansible-playbook playbooks/k3s/kube-vip.yml --ask-pass --check --forks 1
```

### Run

```bash
ansible-playbook playbooks/k3s/kube-vip.yml --ask-pass --ask-become-pass --forks 1
```

---

## Verification

```
[ ] ping 192.168.0.10                                      → VIP responds
[ ] kubectl get nodes                                      → all 6 nodes Ready
[ ] kubectl config view --minify | grep server             → shows 192.168.0.10
[ ] kubectl get pods -n kube-system | grep kube-vip        → 3 pods (one per server)
[ ] Shut down node01 → kubectl get nodes still responds    → failover confirmed
[ ] Power node01 back on → cluster healthy                 → re-join confirmed
```

---

## Debugging History

This took several attempts. Documenting for future reference.

### Attempt 1 — static pod with serviceAccountName

Failed immediately with:
```
mirror pod may not reference service accounts
```
Kubernetes hard-enforces this. Static pods are mirror pods — they cannot use ServiceAccounts. Removed `serviceAccountName` from the manifest.

### Attempt 2 — static pod with mounted kubeconfig

kube-vip needs cluster access for Lease operations. Without a ServiceAccount, we tried mounting the k3s kubeconfig:
```yaml
volumeMounts:
  - name: kubeconfig
    mountPath: /etc/kubernetes/admin.conf
volumes:
  - name: kubeconfig
    hostPath:
      path: /etc/rancher/k3s/k3s.yaml
```
Used `--k8sConfigPath /etc/kubernetes/admin.conf` (correct flag name per `kube-vip manager --help`).

`crictl inspect` confirmed the mount was correct. But kube-vip still ignored the file and tried to connect to `https://kubernetes:6443`. The DNS lookup went to 1.1.1.1 (host DNS) instead of CoreDNS because the pod uses `hostNetwork: true`.

Root cause: k3s.yaml has `server: https://127.0.0.1:6443`. kube-vip's in-cluster config ignores the file and builds the URL from `KUBERNETES_SERVICE_HOST` env var — which is not set in a static pod context. It falls back to resolving `kubernetes` via DNS.

### Attempt 3 — /etc/hosts workaround on node01

Added `127.0.0.1 kubernetes` to `/etc/hosts` on node01. Restarted k3s.

**This worked.** kube-vip started, acquired the lease, and the VIP came up:

```
2026/05/04 02:14:24 INFO cluster membership namespace=kube-system lock=plndr-cp-lock id=ubuntu
Successfully acquired lease lock="kube-system/plndr-cp-lock"
2026/05/04 02:14:24 INFO layer 2 broadcaster starting IP=192.168.0.10 device=enp1s0
PING 192.168.0.10 ... 0% packet loss
```

But this is not sustainable — it requires `/etc/hosts` management on every server node and is not idempotent under Ansible without custom tasks.

### Final approach — DaemonSet (clean, no hacks)

Replaced static pods with DaemonSets. Three DaemonSets, one per server node, each with `nodeSelector: kubernetes.io/hostname` pointing at the right host. Each DaemonSet hardcodes the correct interface for its node.

DaemonSet pods are real pods: serviceAccountName works, in-cluster config works, CoreDNS works. The static pod manifest is cleaned up by the playbook before deploying.

---

## Version

Pinned to `v1.1.2` (latest stable as of May 2026).
Check releases: https://github.com/kube-vip/kube-vip/releases
