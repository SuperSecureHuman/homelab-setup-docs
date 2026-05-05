# Chapter 10 — Ingress

## What we're building

NPM handles TLS termination today. This adds an in-cluster ingress layer between NPM and the apps — host-based routing, sticky sessions, middleware, all managed as k8s manifests.

```
Internet → NPM (TLS) → NodePort on all nodes → Traefik pod (per node) → App pods
```

NPM stays. It still owns the certs and the port-forward. Traefik handles routing once traffic enters the cluster.

---

## MetalLB is not a load balancer

Worth clarifying before anything else.

MetalLB in L2 mode answers ARP for assigned VIPs. One node wins the election and **all traffic for that VIP enters through that one node's NIC**. kube-proxy then picks a pod.

- MetalLB's job: make a `Service` IP reachable from outside by winning ARP
- kube-proxy's job: distribute traffic to pod endpoints

Same story for kube-vip at `192.168.0.10` — one node holds the VIP at a time. VIP, not load balancer.

> L2 mode is single-node entry. One NIC receives all traffic for a given VIP. MetalLB does failover (another node takes over in seconds) but not simultaneous multi-node distribution. BGP mode + a BGP-capable router is needed for that.

This matters for ingress because kube-proxy has no concept of cookies or session state — it picks pods randomly. For sticky sessions to work, the ingress controller has to handle routing itself, not kube-proxy.

---

## How ingress controllers bypass kube-proxy

All major controllers watch **EndpointSlices** directly. They build their own upstream pool from pod IPs and connect to pods directly — kube-proxy is never involved.

```
Traefik pod (node01)
  │
  │  EndpointSlice for "my-app":
  │   → pod A: 10.42.0.15  (node02)
  │   → pod B: 10.42.1.8   (node04)
  │
  ├─→ 10.42.0.15 ──[Flannel VXLAN]──→ node02 → pod A
  └─→ 10.42.1.8  ──[Flannel VXLAN]──→ node04 → pod B
```

Pod IPs are routable cluster-wide via Flannel. A Traefik pod on node01 can connect directly to a pod on node04 with no extra hops.

---

## Traefik vs NGINX

`kubernetes/ingress-nginx` was archived March 24, 2026 — no security patches ever again. Not an option.

The real comparison: **Traefik v3** vs **`nginxinc/kubernetes-ingress`** (F5 NGINX, not the dead community one).

| | Traefik v3 | nginxinc/kubernetes-ingress |
|---|---|---|
| Status | Active — v3.6.15 (Apr 2026) | Active — v5.4.1 (Mar 2026) |
| Maintainer | Traefik Labs | F5 NGINX |
| GitHub stars | 63,000 | ~5,000 |
| Routes to pod IPs directly | Yes (default) | Yes (default) |
| Sticky sessions — OSS | Yes — SHA-256 of pod URL | Yes — MD5 of pod IP:port |
| Sticky across multiple instances | Yes — hash is deterministic | Yes — hash is deterministic |
| Native Let's Encrypt | Yes | No |
| Dashboard | Yes | No |
| TCP routing | `IngressRouteTCP` CRD | `TransportServer` CRD |
| Idle RAM | ~50–100 Mi | ~60–120 Mi |
| ArgoCD deployable | Yes | Yes |

nginxinc is solid — the feature gap isn't dramatic. Traefik wins on community (far more homelab examples and answers), native ACME, and the dashboard. **Going with Traefik.**

---

## Architecture

### Why NodePort instead of a MetalLB VIP

A single Traefik `LoadBalancer` service gets one MetalLB VIP, which lives on one node (L2 ARP). All ingress traffic enters through that one NIC regardless of how many Traefik replicas exist elsewhere.

NodePort exposes Traefik on every node. NPM can then load balance across all node IPs — distributing traffic at the point where NPM hands off to the cluster, not inside it.

### The flow

```
Internet
    ↓ HTTPS
NPM (192.168.0.180)   ← single internet entry, owns TLS
    ↓ HTTP, least_conn upstream across all nodes
  ┌──────┬──────┬──────┬──────┬──────┬──────┐
  ↓      ↓      ↓      ↓      ↓      ↓      ↓
.104   .105   .201   .202   .203   .204
:30080 :30080 :30080 :30080 :30080 :30080
  ↓      ↓      ↓      ↓      ↓      ↓
Traefik (DaemonSet — one pod per node)
                   ↓
     pod IPs on any node via Flannel VXLAN
```

- DaemonSet guarantees one Traefik pod on every node
- `externalTrafficPolicy: Local` — traffic arriving at `node03:30080` goes only to the Traefik pod on node03, no cross-node kube-proxy hop, and NPM's real IP is preserved as `remote_addr`
- NPM (OpenResty under the hood) supports active health checks — see NPM config section below

### Sticky sessions across instances

Traefik's sticky cookie value = `SHA-256("http://<pod_ip>:<port>")[:16]`.

SHA-256 is deterministic. Every Traefik instance computes the same hash for the same pod URL. A cookie set by Traefik on node01 is honored correctly by Traefik on node05 — they both know the same pod IPs (same EndpointSlices) and produce the same hash.

What does **not** work across instances without extra config:
- Rate limiting — each pod has its own in-memory counter. Use Redis backend for distributed rate limiting if needed.
- Circuit breakers — per-pod failure state.

---

## NPM config

NPM runs on OpenResty (not plain nginx) — specifically OpenResty 1.27.1.2 with LuaJIT. This matters because `lua-resty-upstream-healthcheck` ships inside the OpenResty tarball and is available in NPM without any container rebuild.

Everything below is file-based. No UI interaction needed — drop files directly on the NAS and reload nginx.

### Upstream block

`/data/nginx/custom/http.conf` — included inside nginx's `http {}` block:

```nginx
upstream traefik_nodes {
    least_conn;
    server 192.168.0.104:30080 max_fails=3 fail_timeout=30s;
    server 192.168.0.105:30080 max_fails=3 fail_timeout=30s;
    server 192.168.0.201:30080 max_fails=3 fail_timeout=30s;
    server 192.168.0.202:30080 max_fails=3 fail_timeout=30s;
    server 192.168.0.203:30080 max_fails=3 fail_timeout=30s;
    server 192.168.0.204:30080 max_fails=3 fail_timeout=30s;
}
```

After writing the file, reload: `nginx -s reload` inside the NPM container.

### Wildcard proxy host

Create `/data/nginx/proxy_host/<n>.conf` directly as a file. Pick the next unused number.

```nginx
# *.yourdomain.com → Traefik

map $scheme $hsts_header {
    https   "max-age=63072000; preload";
}

server {
  set $forward_scheme http;
  set $server         "traefik_nodes";
  set $port           30080;

  listen 80;
  listen [::]:80;

  listen 443 ssl;
  listen [::]:443 ssl;

  server_name *.yourdomain.com;

  ssl_certificate     /data/custom_ssl/npm-<id>/fullchain.pem;
  ssl_certificate_key /data/custom_ssl/npm-<id>/privkey.pem;

  proxy_set_header Upgrade    $http_upgrade;
  proxy_set_header Connection $http_connection;
  proxy_http_version 1.1;

  access_log /data/logs/proxy-host-traefik_access.log proxy;
  error_log  /data/logs/proxy-host-traefik_error.log warn;

  location / {
    proxy_set_header Upgrade            $http_upgrade;
    proxy_set_header Connection         $http_connection;
    proxy_http_version 1.1;

    proxy_set_header Host               $host;
    proxy_set_header X-Real-IP          $remote_addr;
    proxy_set_header X-Forwarded-For    $remote_addr;
    proxy_set_header X-Forwarded-Proto  $scheme;
    proxy_set_header X-Forwarded-Scheme $scheme;

    proxy_pass http://traefik_nodes;
  }

  include /data/nginx/custom/server_proxy[.]conf;
}
```

> Do NOT include `conf.d/include/proxy.conf` here. NPM's standard proxy.conf uses `$server` and `$port` variables to build `proxy_pass`. Since we're pointing at a named upstream directly, we skip it and write `proxy_pass http://traefik_nodes` ourselves.

> SSL: the cert at `npm-<id>` must be a wildcard cert (`*.yourdomain.com`). NPM's built-in Let's Encrypt uses HTTP-01, which can't issue wildcards. Get the cert via DNS-01 challenge (acme.sh or cert-manager with a DNS provider) and upload it manually under **SSL Certificates → Custom**.

### Per-app routing

Once the wildcard proxy host is in place, adding a new app needs nothing on the NPM side. Just add an `IngressRoute` in the cluster:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: my-app
  namespace: my-namespace
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`my-app.yourdomain.com`)
      kind: Rule
      services:
        - name: my-app-svc
          port: 8080
```

NPM passes the `Host` header through unchanged. Traefik receives the original hostname and routes by it.

### Health checks

Passive (default, no extra config): after `max_fails=3` failures within `fail_timeout=30s`, that node is skipped for 30 seconds. Enough for most cases.

Active (OpenResty Lua, probes nodes on a timer regardless of live traffic):

`/data/nginx/custom/http_top.conf`:
```nginx
lua_shared_dict healthcheck 1m;
```

Add to `/data/nginx/custom/http.conf` after the upstream block:
```nginx
init_worker_by_lua_block {
    local hc = require "resty.upstream.healthcheck"
    local ok, err = hc.spawn_checker({
        shm            = "healthcheck",
        upstream       = "traefik_nodes",
        type           = "http",
        http_req       = "GET /ping HTTP/1.0\r\nHost: traefik_nodes\r\n\r\n",
        interval       = 2000,
        timeout        = 1000,
        fall           = 3,
        rise           = 2,
        valid_statuses = {200},
        concurrency    = 10,
    })
}
```

Traefik exposes `/ping` on port 30080 by default (returns `200 OK`). The upstream name in `spawn_checker` must match the upstream block name exactly.

> For a homelab where nodes rarely die, passive checks are sufficient. Use active checks if you want instant failover without waiting for a real user request to hit a dead node first.

### Headers

NPM already sends the right headers by default — no extra config needed:

| Header | Value | Why it matters |
|---|---|---|
| `Host` | `$host` | Original hostname preserved — Traefik routes by it |
| `X-Forwarded-Proto` | `$scheme` (= `https`) | Prevents HTTP→HTTPS redirect loop at Traefik |
| `X-Real-IP` | `$remote_addr` | NPM's IP — Traefik sees this |

Tell Traefik to trust NPM's forwarded headers — otherwise it ignores `X-Forwarded-Proto` by default (security measure against IP spoofing):

```yaml
# traefik values
ports:
  web:
    forwardedHeaders:
      trustedIPs:
        - "192.168.0.180/32"
  websecure:
    forwardedHeaders:
      trustedIPs:
        - "192.168.0.180/32"
```

Without this, Traefik sees HTTP from NPM and tries to redirect to HTTPS — even though NPM already handled TLS. The redirect loop is the symptom.

---

## Deployment via ArgoCD

k3s's bundled Traefik is already disabled (`--disable traefik` in k3s config). We deploy our own via ArgoCD.

Helm values at `homelab-argo/values/traefik/values.yaml`:

```yaml
deployment:
  kind: DaemonSet

service:
  type: NodePort
  spec:
    externalTrafficPolicy: Local

ports:
  web:
    nodePort: 30080
  websecure:
    nodePort: 30443

entryPoints:
  web:
    forwardedHeaders:
      trustedIPs:
        - "192.168.0.180/32"
  websecure:
    forwardedHeaders:
      trustedIPs:
        - "192.168.0.180/32"

providers:
  kubernetesCRD:
    allowCrossNamespace: true
```

ArgoCD Application at `homelab-argo/argocd/apps/traefik.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: traefik
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://traefik.github.io/charts
    chart: traefik
    targetRevision: "34.x.x"
    helm:
      valueFiles:
        - $values/homelab-argo/values/traefik/values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: traefik
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

---

## Routing an app

Apps use `ClusterIP` services — no `LoadBalancer` needed. Traefik handles external access.

For sticky sessions, use a `TraefikService` to define the load balancing config, then reference it from an `IngressRoute`:

```yaml
apiVersion: traefik.io/v1alpha1
kind: TraefikService
metadata:
  name: my-app
  namespace: default
spec:
  weighted:
    services:
      - name: my-app-svc
        port: 8080
        weight: 1
    sticky:
      cookie:
        name: stickysession
        httpOnly: true
        secure: true
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: my-app
  namespace: default
spec:
  entryPoints:
    - web
  routes:
    - match: "Host(`app.yourdomain.com`)"
      kind: Rule
      services:
        - name: my-app
          kind: TraefikService
```

For apps that don't need sticky sessions, skip `TraefikService` and point the `IngressRoute` directly at the Kubernetes service.

---

## Verify

```bash
# DaemonSet running — one pod per node
kubectl get pods -n traefik -o wide

# NodePort open on all nodes
curl http://192.168.0.104:30080
curl http://192.168.0.105:30080

# Test host routing
kubectl create deployment test --image=nginx
kubectl expose deployment test --name=test-svc --port=80
# apply IngressRoute for Host(`test.yourdomain.com`)
curl -H "Host: test.yourdomain.com" http://192.168.0.104:30080

# Dashboard
kubectl port-forward -n traefik svc/traefik 9000:9000
# open http://localhost:9000/dashboard/

# Cleanup
kubectl delete deployment test && kubectl delete svc test-svc
```
