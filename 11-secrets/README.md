# Chapter 11 — Secrets Management (ESO + Infisical)

## Why

Grafana password, NAS DB credentials, ArgoCD repo token — all plaintext in git or hand-applied with kubectl. External Secrets Operator (ESO) + Infisical moves them out: secrets live in Infisical, ESO syncs them into the cluster as regular Kubernetes Secrets on a schedule. Apps read a normal Secret and nothing changes on their end.

---

## How it works

ESO watches `ExternalSecret` resources. When it finds one, it authenticates with Infisical, fetches the value, and creates or updates a Kubernetes Secret.

```
ExternalSecret
  │  "fetch GRAFANA_ADMIN_PASSWORD from Infisical"
  ▼
ESO controller  ──→  eu.infisical.com
  │               authenticate + fetch value
  ▼
Secret (regular k8s Secret, any namespace)
  ▼
App pod mounts it normally
```

One `ClusterSecretStore` handles auth. Any namespace can point `ExternalSecret` resources at it.

---

## Authentication

Kubernetes Auth is the secretless option — ESO uses its own service account JWT and nothing needs to live in the cluster. Not usable here: Infisical hosted needs to call back to the K3s API at `192.168.0.10:6443` to validate tokens via TokenReview. Private network, not reachable from `eu.infisical.com`.

**Universal Auth** instead: one bootstrapped Kubernetes Secret holds a clientId and clientSecret. ESO exchanges them for short-lived access tokens from Infisical. That one secret is the only thing managed by hand — everything else flows from Infisical.

> To upgrade to Kubernetes Auth later: expose the K3s API via Cloudflare Tunnel. Don't use NPM TCP stream proxying — that puts the full control plane on the internet. Once the API is reachable, swap `universalAuthCredentials` for `kubernetesAuthCredentials` in the ClusterSecretStore and delete the bootstrap secret.

---

## Infisical setup (one-time, UI)

1. Organization Settings → Access Control → Machine Identities → **Create Identity**. Name it `homelab-k8s`.
2. Edit the identity → Authentication → **Add Auth Method → Universal Auth**. Copy the Client ID. Generate a Client Secret — shown once, copy it now.
3. `home-lab-supersecurehuman` project → Settings → Access Control → Machine Identities → **Add `homelab-k8s`** with Developer role.

---

## Kubernetes bootstrap (one-time, not in git)

```bash
kubectl create namespace external-secrets

kubectl create secret generic infisical-universal-auth \
  --from-literal=clientId=<CLIENT_ID> \
  --from-literal=clientSecret=<CLIENT_SECRET> \
  -n external-secrets
```

That's the only credential that ever lives manually in the cluster.

---

## ArgoCD app

Single multi-source Application: ESO Helm chart + ClusterSecretStore manifest together, same pattern as `prom-stack`.

`homelab-argo/argocd/apps/external-secrets.yaml` is in the repo. Apply it manually on first deploy or let app-of-apps pick it up.

`ServerSideApply=true` is required — ESO's CRDs exceed the 256 KB client-side apply limit.

Chart: `external-secrets/external-secrets` from `https://charts.external-secrets.io`, pinned at `2.4.1`.

---

## ClusterSecretStore

`homelab-argo/manifests/external-secrets/cluster-secret-store.yaml`

`ClusterSecretStore` (not `SecretStore`) — any namespace can reference it. Scoped to `home-lab-supersecurehuman`, `prod` environment, path `/`.

The `namespace: external-secrets` on the credential refs is required for ClusterSecretStore — ESO needs it to know where to look for the bootstrap secret.

---

## Using ExternalSecrets

Add an `ExternalSecret` in any namespace to pull secrets from Infisical:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: grafana-admin
  namespace: monitoring
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: infisical-cluster-store
  refreshInterval: 1h
  target:
    name: grafana-admin-credentials
    creationPolicy: Owner
  data:
    - secretKey: admin-password
      remoteRef:
        key: GRAFANA_ADMIN_PASSWORD   # key name in Infisical
```

`remoteRef.key` is the key name in Infisical. `secretKey` is the key name inside the resulting Kubernetes Secret.

To pull everything under the store's path at once:

```yaml
  dataFrom:
    - find:
        name:
          regexp: .*
```

---

## Notes

### First sync race

On first deploy, ArgoCD applies the Helm resources and the ClusterSecretStore simultaneously. The ClusterSecretStore CRD may not exist yet — ArgoCD will show a sync error on that resource. The `sync-wave: "1"` annotation on the manifest delays it, but if it still fails, hit Sync again once ESO pods are running. It self-heals.

### One store per environment

The ClusterSecretStore has `environmentSlug: prod` fixed. For dev or staging, create a second ClusterSecretStore with a different name pointing at the right environment slug.

### refreshInterval

`1h` works for most secrets. Drop it to `5m` when actively rotating something. Set to `0` to disable polling — ESO only syncs on ExternalSecret creation or a manual reconcile trigger.

### creationPolicy

`Owner` — ESO owns the Secret; deletes it when the ExternalSecret is deleted. Use `Merge` to add keys into a pre-existing Secret without touching the rest of it.

---

## Files

```
homelab-argo/
├── argocd/apps/external-secrets.yaml
├── values/external-secrets/values.yaml          (installCRDs: true)
└── manifests/external-secrets/
    └── cluster-secret-store.yaml
```

Bootstrap secret (not in git): `infisical-universal-auth` in `external-secrets` namespace.

---

## Verify

```bash
# ESO pods running
kubectl get pods -n external-secrets

# Store status — Ready: True means auth is working
kubectl get clustersecretstore infisical-cluster-store

# Test with a real ExternalSecret
kubectl apply -f - <<'EOF'
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: eso-test
  namespace: default
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: infisical-cluster-store
  refreshInterval: 1m
  target:
    name: eso-test-secret
    creationPolicy: Owner
  dataFrom:
    - find:
        name:
          regexp: .*
EOF

# Check sync status
kubectl get externalsecret eso-test -n default
kubectl get secret eso-test-secret -n default \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'

# Cleanup
kubectl delete externalsecret eso-test -n default
```
