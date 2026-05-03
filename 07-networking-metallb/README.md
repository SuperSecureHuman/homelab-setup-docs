# Chapter 07 — Networking: MetalLB

## What is MetalLB?

Kubernetes expects a cloud provider to handle `Service` of type `LoadBalancer`. On bare metal there's no cloud — MetalLB fills that gap.

MetalLB watches for `LoadBalancer` Services and assigns them an IP from a configured pool. In **L2 mode** (what we use), it answers ARP requests for those IPs on the LAN, making any assigned VIP reachable from any device on the network.

No BGP router required. No extra hardware.

---

## IP Pool

| Pool name      | Range                         | Subnet           |
|----------------|-------------------------------|------------------|
| `homelab-pool` | `192.168.0.20 – 192.168.0.90` | `192.168.0.0/24` |

This range sits outside the router's DHCP scope to prevent conflicts.

---

## ArgoCD Setup

MetalLB is managed via the argo. Two Applications are needed — one for the helm chart, one for the CRs (IPAddressPool + L2Advertisement) — because the CRs depend on CRDs installed by the chart.


MetalLB assigns a VIP from `192.168.0.20–192.168.0.90`:
```bash
kubectl get svc my-app   # EXTERNAL-IP will be in that range
```

The VIP is immediately reachable from any device on the LAN.

---

## Verify

```bash
# MetalLB pods healthy
kubectl get pods -n metallb-system

# Pool and advertisement created
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system

# Test service gets a VIP
kubectl create deployment test --image=nginx
kubectl expose deployment test --type=LoadBalancer --port=80
kubectl get svc test   # EXTERNAL-IP should populate within ~10s
ping <EXTERNAL-IP>

# Cleanup
kubectl delete deployment test && kubectl delete svc test
```

---

## L2 Mode Internals

- The MetalLB **speaker** DaemonSet pod on each node listens for assigned VIPs.
- One speaker wins ownership and answers ARP requests for each VIP.
- If that node goes down, another speaker takes over within seconds.
- Traffic always hits a cluster node first, then kube-proxy routes to the correct pod.

> L2 mode is single-node ARP — all traffic for a VIP hits one node. Fine for a homelab. BGP mode is needed for true load distribution across nodes. You need a BGP-capable router and more complex setup, but it allows multiple nodes to share the same VIP for better performance and failover.
