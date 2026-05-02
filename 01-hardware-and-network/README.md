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
