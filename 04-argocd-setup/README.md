# Chapter 03 — ArgoCD HA Setup

## Overview

ArgoCD deployed in high-availability mode using the official `ha/install.yaml` manifest.
This variant grants cluster-admin access and manages workloads on the same cluster — the standard choice for a single homelab cluster.

HA adds multiple replicas to the components that support it and runs Redis in Sentinel mode with HAProxy for failover.

## Components Deployed

| Component                        | Replicas (HA)   | Purpose                               |
|----------------------------------|-----------------|---------------------------------------|
| argocd-server                    | 2               | API + Web UI                          |
| argocd-repo-server               | 2               | Git repo cloning + manifest rendering |
| argocd-application-controller    | 1 (StatefulSet) | Reconciliation loop                   |
| argocd-applicationset-controller | 2               | ApplicationSet generation             |
| argocd-dex-server                | 1               | SSO / OIDC provider                   |
| argocd-notifications-controller  | 1               | Notification delivery                 |
| redis-ha                         | 3               | In-cluster cache (Sentinel + HAProxy) |

## Prerequisites

- Namespace `argocd` created
- `kubectl` configured pointing to the cluster

## Install

```bash
# 1. Create namespace
kubectl create namespace argocd

# 2. Install ArgoCD HA (cluster-scoped, includes CRDs)
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.9/manifests/ha/install.yaml

# 3. Wait for rollout
kubectl rollout status deployment argocd-server -n argocd
kubectl rollout status deployment argocd-repo-server -n argocd
```

## Initial Admin Password

```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

Login: `admin` / `<above password>`

> Delete the secret after first login: `kubectl delete secret argocd-initial-admin-secret -n argocd`

## Access UI

ArgoCD server is not exposed by default. Options:

**Port-forward (quick test):**
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# https://localhost:8080
```

**Ingress / LoadBalancer:** Configure later

## CLI Login

```bash
# Install argocd CLI
brew install argocd   # macOS

# Login via port-forward
argocd login localhost:8080 --username admin --insecure
```

## Version Pinning

Current version: `v3.3.9`

To upgrade, update the version in the install commands above and re-apply.
Check releases: https://github.com/argoproj/argo-cd/releases

## Upgrade

```bash
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v<NEW>/manifests/ha/install.yaml
```

## Connecting homelab-argo repo to ArgoCD

All Application manifests in `homelab-argo` reference this repo for values. ArgoCD must be able to clone it. The repo is public but registering it with a token avoids anonymous rate-limits and is required if it ever goes private.

### 1 — Create a fine-grained GitHub token
Use the webui to create a token with `contents:read` scope on the `homelab-argo` repo only. This limits blast radius if the token is ever exposed.

```bash
echo "Token: $TOKEN"   # copy this — shown only once
```

### 2 — Register the repo in ArgoCD

ArgoCD reads repo credentials from a labelled Kubernetes secret in the `argocd` namespace.

```bash
kubectl create secret generic homelab-argo-repo \
  -n argocd \
  --from-literal=type=git \
  --from-literal=url=https://github.com/SuperSecureHuman/homelab-argo.git \
  --from-literal=username=SuperSecureHuman \
  --from-literal=password="$TOKEN"

kubectl label secret homelab-argo-repo \
  -n argocd \
  argocd.argoproj.io/secret-type=repository
```

### 3 — Verify

```bash
# Repo should appear as Connected
argocd repo list

# Or via kubectl
kubectl get secret homelab-argo-repo -n argocd \
  -o jsonpath='{.metadata.labels}' | jq
```

### Token rotation

When the token expires, delete the secret and repeat steps 1–2 with a new token name (e.g. `argocd-homelab-argo-2`). ArgoCD picks up the change immediately without restart.

---

## App of Apps Bootstrap

All child apps (`nfs-provisioner`, `prom-stack`, etc.) live as manifests under `homelab-argo/argocd/apps/`. A single root Application watches that directory — when you push a new app manifest to the repo, ArgoCD creates it automatically. No manual `kubectl apply` per app.

### Root Application manifest

Apply this once via the ArgoCD CLI after ArgoCD is installed and the repo is registered (section above).

```bash
argocd app create root \
  --repo https://github.com/SuperSecureHuman/homelab-argo.git \
  --path argocd/apps \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace argocd \
  --sync-policy automated \
  --auto-prune \
  --self-heal \
  --revision main
```

Alternatively, create it through the ArgoCD UI: **+ New App → fill in the same values → Create**.

### How it works

```
homelab-argo/argocd/apps/
  nfs-provisioner.yaml   ← root app detects this → creates nfs-provisioner Application  ...
```

From this point, adding a new app = push a manifest to `argocd/apps/`. ArgoCD syncs it within ~3 minutes (default polling interval).

### Verify

```bash
# Root app and all child apps should be Healthy + Synced
argocd app list
```

---

## Troubleshooting

### "Unable to load data: server.secretkey is missing"

The HA manifest leaves `argocd-secret` empty and expects the key to be set externally. If the secret was never populated, the UI fails to load with this error.

**Fix:**

```bash
kubectl patch secret argocd-secret -n argocd \
  -p "{\"stringData\": {\"server.secretkey\": \"$(openssl rand -base64 32)\"}}"

kubectl rollout restart deployment/argocd-server -n argocd
```

The server pods will restart and pick up the new key. All existing sessions will be invalidated (users need to log in again).

## Verification

```
[ ] kubectl get pods -n argocd                  → all pods Running
[ ] kubectl get svc -n argocd                   → argocd-server service present
[ ] port-forward + browser https://localhost:8080 → login page loads
[ ] login with admin + initial password          → dashboard accessible
[ ] redis-ha pods (x3) all Running               → HA cache healthy
```
