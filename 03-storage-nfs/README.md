# Chapter 03 — Storage: NFS

## Design

All persistent data lives on NFS — nodes use zero local storage for PVCs. One StorageClass:

| StorageClass | NFS Server | Path | Default? | Use for |
|---|---|---|---|---|
| `nfs-nas` | `192.168.0.180` | `/mnt/ssd_mirror/k8s_volume` | **Yes** | All app PVCs |

Dynamic provisioning via `nfs-subdir-external-provisioner` — watches for PVCs and automatically creates a subdirectory on the NFS share.

When a PVC is deleted: `reclaimPolicy: Retain` + `archiveOnDelete: true` — the directory is renamed with a timestamp prefix instead of deleted. No accidental data loss.

---

## Step 1 — TrueNAS Share Setup

**Sharing → NFS → Add (or edit existing share):**

| Setting | Value |
|---|---|
| Path | `/mnt/ssd_mirror/k8s_volume` |
| Maproot User | `root` |
| Maproot Group | `wheel` |
| Authorized Networks | `192.168.0.0/24` |

> **Maproot User = root** is the critical setting. Without it TrueNAS applies `root_squash` — root on the cluster nodes gets remapped to `nobody` and all writes fail with Permission denied.

**Services → NFS → Start** (enable autostart).

Verify from any cluster node:
```bash
showmount -e 192.168.0.180
```

---

## Step 2 — Benchmark NFS Speed

Before installing the provisioner, verify the share is reachable and fast enough from all nodes.
Run from `homelab-ansible/`:

```bash
# Serial run — accurate per-node numbers
ansible-playbook playbooks/nfs-benchmark.yml \
  -e nfs_server=192.168.0.180 \
  -e nfs_path=/mnt/ssd_mirror/k8s_volume \
  --forks 1 \
  --ask-pass --ask-become-pass
```

Each node mounts the share, writes 512 MB with `fdatasync` (bypasses write cache), drops page cache, reads back. Results per node at the end.

### Baseline results (2026-05-02, 512 MB, serial)

| Node | Arch | Write | Read |
|---|---|---|---|
| node01 | x86_64 | 110 MB/s | 117 MB/s |
| node02 | x86_64 | 98 MB/s | 117 MB/s |
| pi-node02 | arm64 | 102 MB/s | 117 MB/s |
| pi-node01 | arm64 | 103 MB/s | 113 MB/s |
| pi-node03 | arm64 | 103 MB/s | 114 MB/s |
| pi-node04 | arm64 | 78.8 MB/s | 116 MB/s |

All nodes are near gigabit line rate (~119 MB/s theoretical). pi-node04 write is slightly lower — likely a difference in its network path or NIC.

> **Don't run without `--forks 1`** for baseline measurements. All 6 nodes writing in parallel saturates the NAS uplink and each sees ~24 MB/s — not the node's real capability.

### If a run fails mid-way (mounts left behind)

```bash
ansible k3s_cluster -m shell \
  -a 'umount /tmp/nfs-benchmark-$(hostname) 2>/dev/null; rm -rf /tmp/nfs-benchmark-$(hostname)' \
  --become --ask-pass --ask-become-pass
```

---

## Step 3 — Install Provisioner

```bash
helm repo add nfs-subdir-external-provisioner \
  https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
helm repo update

helm install nfs-provisioner-nas \
  nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
  -n nfs-provisioner --create-namespace \
  -f configs/nfs-provisioner-nas.yaml
```

---

## Step 4 — Verify Provisioner

```bash
# StorageClass present, nfs-nas marked (default)
kubectl get storageclass

# Test PVC — should bind within ~30 seconds
kubectl apply -f configs/test-pvc.yaml
kubectl get pvc test-pvc   # STATUS should be Bound

# Verify subdirectory was created on the NAS
ls /mnt/ssd_mirror/k8s_volume/

# Cleanup
kubectl delete pvc test-pvc
```

---

## Using PVCs in Apps

No StorageClass annotation needed — `nfs-nas` is the default:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-app-data
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
```

### Access Modes

| Mode | Meaning |
|---|---|
| `ReadWriteOnce` (RWO) | One node reads+writes |
| `ReadOnlyMany` (ROX) | Many nodes read |
| `ReadWriteMany` (RWX) | Many nodes read+write — useful for shared storage (e.g. media servers) |
