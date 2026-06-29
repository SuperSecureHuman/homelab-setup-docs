# Known Issues — Pi-hole HA

## k3s flannel VXLAN binds to keepalived VIP on startup

### Status

Fixed in `homelab-ansible/inventory/group_vars/k3s_cluster.yml`.

### Symptom

k3s networking breaks on a node after it **loses** a keepalived VIP. Pod-to-pod traffic across nodes fails; flannel VXLAN traffic stops flowing.

### Root Cause

Keepalived assigns VIPs (`192.168.0.251`, `192.168.0.252`) as secondary IPs on the primary NIC. If k3s starts while a VIP is present on the interface, flannel auto-detects all IPs on that interface and may bind its VXLAN tunnel source to the VIP instead of the stable node IP.

`node-ip` in k3s config pins the node's **registration IP** correctly — but it does not constrain which IP flannel uses for the VXLAN tunnel. When the VIP migrates to another node, the tunnel source IP disappears from the interface and the node loses cluster networking.

### Fix

`flannel-iface` added to both `server_config_yaml` and `agent_config_yaml` in `k3s_cluster.yml`:

```yaml
flannel-iface: "{{ ansible_host }}"
```

`flannel-iface` accepts an IP address. Passing the stable node IP forces flannel to bind the VXLAN tunnel to that exact IP only, ignoring any VIPs present on the same interface.

### Affected Nodes

Any node that can hold a keepalived VIP and also runs k3s — currently `node01` (192.168.0.104) and `node02` (192.168.0.105), which have high priority for both VIPs.

### Verification

After rolling `flannel-iface` out (restart k3s on each node):

```bash
# VTEP IP should match the stable node IP, not a VIP
ip addr show flannel.1

# Simulate VIP loss: stop keepalived on a node holding a VIP
# k3s networking should stay up
sudo systemctl stop keepalived
kubectl get nodes   # should still show Ready
kubectl exec -it <pod> -- ping <cross-node-pod-ip>

sudo systemctl start keepalived
```
