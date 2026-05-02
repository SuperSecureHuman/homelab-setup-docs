# Chapter 01 — Hardware & Network

## Nodes

| Node | IP | Hostname | Arch | RAM | Cores | Storage | Model | Role |
|---|---|---|---|---|---|---|---|---|
| TrueNAS | 192.168.0.180 | truenas | x86_64 | 16GB | 4 | 112G SSD + 2×18.2T HDD + 3.6T HDD + 2×1.9T NVMe | Intel N150 | Gateway + NFS primary — **NOT in cluster** |
| x86 Node A | 192.168.0.104 | ubuntu | x86_64 | 16GB | 4 | 477G SSD | Intel N95 | k3s server + NFS backup export |
| x86 Node B | 192.168.0.105 | node02 | x86_64 | 16GB | 4 | 239G NVMe | Intel i5-6500T | k3s server |
| Pi 5 (16GB) | 192.168.0.202 | pi-node02 | arm64 | 16GB | 4 | 119G SD | Raspberry Pi 5 Model B Rev 1.1 | k3s server (3rd etcd member) |
| Pi 4 (8GB) | 192.168.0.204 | pi-node04 | arm64 | 8GB | 4 | 119G SD | Raspberry Pi 4 Model B Rev 1.5 | k3s agent |
| Pi 5 (8GB) #1 | 192.168.0.201 | pi-node01 | arm64 | 8GB | 4 | 119G SD | Raspberry Pi 5 Model B Rev 1.0 | k3s agent |
| Pi 5 (8GB) #2 | 192.168.0.203 | pi-node03 | arm64 | 8GB | 4 | 119G SD | Raspberry Pi 5 Model B Rev 1.0 | k3s agent |
| Switch | 192.168.0.200 | switchy | — | — | — | — | — | Network switch |

## IP Plan

| Variable | Value | Host | Notes |
|---|---|---|---|
| `NAS_IP` | 192.168.0.180 | truenas | NAS/NPM node — gateway, NFS primary |
| `SERVER_A_IP` | 192.168.0.104 | ubuntu | x86 Node A — k3s server + NFS backup |
| `SERVER_B_IP` | 192.168.0.105 | node02 | x86 Node B — k3s server |
| `SERVER_PI5_16_IP` | 192.168.0.202 | pi-node02 | Pi 5 16GB — k3s server |
| `AGENT_PI4_IP` | 192.168.0.204 | pi-node04 | Pi 4 8GB — k3s agent |
| `AGENT_PI5_1_IP` | 192.168.0.201 | pi-node01 | Pi 5 8GB #1 — k3s agent |
| `AGENT_PI5_2_IP` | 192.168.0.203 | pi-node03 | Pi 5 8GB #2 — k3s agent |
| `SWITCH_IP` | 192.168.0.200 | switchy | Network switch |
| `METALLB_POOL_START` | TBD | — | Start of MetalLB VIP range (outside DHCP pool) |
| `METALLB_POOL_END` | TBD | — | End of MetalLB VIP range |

**Tip:** Reserve all node IPs via DHCP reservations on your router — easier to manage than static interface config, and survives OS reinstalls.

## Network Topology

```
Internet
    │
  Router  (port forward 80/443 → NAS_IP)
    │
  TrueNAS/NPM (192.168.0.180)  ──── NFS share (/mnt/nas-pool/k3s-pvcs)
    │
  Switch (192.168.0.200)
    ├── x86 Node A / ubuntu  (192.168.0.104)  k3s server + NFS backup
    ├── x86 Node B / node02  (192.168.0.105)  k3s server
    ├── Pi 5 16GB / pi-node02 (192.168.0.202)  k3s server (etcd)
    ├── Pi 4 8GB  / pi-node04 (192.168.0.204)  k3s agent
    ├── Pi 5 8GB  / pi-node01 (192.168.0.201)  k3s agent
    └── Pi 5 8GB  / pi-node03 (192.168.0.203)  k3s agent
```

MetalLB VIPs live on the same LAN subnet — NPM proxies to them by IP.

## Prerequisites — Network Health Checks

Before moving on to cluster setup, verify that all nodes can communicate cleanly.
Automation lives in `../homelab-ansible/`.

### 1. NIC Speed & Duplex

Confirms every NIC negotiated at 1 Gbps full-duplex with no auto-negotiation failures.
A node stuck at 100 Mbps or half-duplex will bottleneck the entire cluster.

```bash
ansible-playbook playbooks/network/health-check.yml --ask-pass --ask-become-pass
```

Checks per node (via `ethtool`):
- Speed (expect `1000Mb/s`)
- Duplex (expect `Full`)
- Auto-negotiation (expect `on`)
- Link detected (expect `yes`)

### 2. Ping Matrix

Every node pings every other node (5 packets, 1s timeout). Catches routing issues,
firewall rules, or misconfigured interfaces before they surface as mysterious k3s
failures. Same playbook as above.

Expected output per pair: `0% packet loss`, RTT under 1 ms on the local LAN.

### 3. iperf3 Throughput Matrix

Each node takes a turn as the iperf3 server; all others connect to it in sequence.
Produces N×(N-1) = 30 measurements across the 6 cluster nodes.

```bash
ansible-playbook playbooks/network/iperf-matrix.yml --ask-pass --ask-become-pass
```

Expected: each flow ~940 Mbps (wire speed minus TCP overhead on 1 GbE).
Anything below ~800 Mbps warrants investigation (cable, switch port, NIC settings).

### 4. Non-Blocking Switch Test

Runs 3 simultaneous independent flows for 10 seconds:

| Client | Server |
|---|---|
| pi-node02 | node01 |
| pi-node03 | node02 |
| pi-node04 | pi-node01 |

Same playbook as above (runs after the matrix).

**How to read the results:**

| Result | Meaning |
|---|---|
| Each flow ~940 Mbps | Switch is non-blocking — all ports get full 1 GbE simultaneously |
| Flows each get ~313 Mbps (total ~940 Mbps) | Switch is blocking / oversubscribed |
| Mixed speeds | Port or cable issue on specific nodes |

A 1 Gbps unmanaged switch with a non-blocking fabric should pass this. If it fails,
traffic between nodes will contend at the switch and degrade k3s etcd and pod
communication under load.

## Known Hardware Limitations

### node02 — NIC send throughput cap (~808-839 Mbps)

`ethtool -k eno1` shows `tcp-segmentation-offload: off [fixed]` — the onboard Intel
NIC on the i5-6500T does not support TCP Segmentation Offload in hardware and cannot
be enabled. The kernel falls back to software GSO, which adds CPU overhead on the
send path.

**Effect:** node02 sends at ~808-839 Mbps to any destination. Receive path is
unaffected (GRO is on) — all nodes sending *to* node02 achieve ~940 Mbps.

**Impact on cluster:** negligible. etcd traffic is in the KB/s range and pod-to-pod
workloads on a homelab cluster will never saturate 800 Mbps. Not worth replacing the
hardware for.

**References to study:**

- [Linux kernel — Segmentation Offloads](https://www.kernel.org/doc/html/latest/networking/segmentation-offloads.html)
  — canonical explanation of TSO, GSO, GRO, LRO and how they interact
- [ethtool man page](https://man7.org/linux/man-pages/man8/ethtool.8.html)
  — `-k` (show features), `-K` (set features), `-S` (NIC stats), `-i` (driver info)
- [Red Hat — Network Performance Tuning Guide](https://access.redhat.com/sites/default/files/attachments/20150325_network_performance_tuning.pdf)
  — TCP buffer sizing (`wmem`/`rmem`), interrupt coalescing, offload tradeoffs
- [Brendan Gregg — Linux Performance](https://www.brendangregg.com/linuxperf.html)
  — broader systems performance methodology; networking section covers NIC stack profiling

**iperf3 matrix baseline (sender Mbps, measured 2026-05-02):**

| sender → | node01 | node02 | pi-node01 | pi-node02 | pi-node03 | pi-node04 |
|---|---|---|---|---|---|---|
| **node01** | — | 947 | 947 | 946 | 947 | 946 |
| **node02** | 808 | — | 808 | 839 | 816 | 806 |
| **pi-node01** | 940 | 939 | — | 940 | 939 | 914 |
| **pi-node02** | 940 | 939 | 939 | — | 939 | 912 |
| **pi-node03** | 940 | 939 | 939 | 939 | — | 912 |
| **pi-node04** | 944 | 944 | 944 | 944 | 944 | — |

Pi 4 (pi-node04) receives at ~912-914 Mbps from Pi 5 nodes — minor, expected for the
Pi 4 NIC generation.

### Non-blocking switch test (measured 2026-05-02)

3 simultaneous flows, 10 seconds each:

| Flow | Speed | |
|---|---|---|
| pi-node02 → node01 | 939 Mbps | wire speed |
| pi-node03 → node02 | 938 Mbps | wire speed |
| pi-node04 → pi-node01 | 921 Mbps | Pi 4 ceiling, expected |

All three flows ran independently at full speed simultaneously (~2.8 Gbps total across
a 1 GbE switch). Switch is **non-blocking** — no port contention under concurrent load.
