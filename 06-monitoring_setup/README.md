# Monitoring Stack

`kube-prometheus-stack` deployed via ArgoCD. Prometheus + Grafana, multiple replicas, metrics scraped from both in-cluster workloads and external hosts (pihole-exporter, etc.).

## Files

| File                                                                                          | Purpose                                         |
|-----------------------------------------------------------------------------------------------|-------------------------------------------------|
| [`homelab-argo/argocd/apps/prom-stack.yaml`](../homelab-argo/argocd/apps/prom-stack.yaml)     | ArgoCD Application manifest                     |
| [`homelab-argo/values/prom-stack/values.yaml`](../homelab-argo/values/prom-stack/values.yaml) | Helm values — replicas, storage, scrape configs |

## ArgoCD Setup

Multi-source Application: Helm chart pulled directly from `prometheus-community`, values pulled from this git repo. ArgoCD auto-syncs on every push to main.

```
homelab-argo/argocd/apps/prom-stack.yaml   ← drop this in the apps/ dir, ArgoCD picks it up
homelab-argo/values/prom-stack/values.yaml ← all tuning lives here
```

Chart version is pinned in the app manifest (`targetRevision: 84.5.0`). Bump it there to upgrade.

To deploy from scratch: just push both files — ArgoCD handles the rest. Namespace `monitoring` is auto-created.

## Replicas

Both Prometheus and Grafana run multiple replicas for HA. Set in `values/prom-stack/values.yaml`:

```yaml
prometheus:
  prometheusSpec:
    replicas: 2

grafana:
  replicas: 2
```

Grafana uses `persistence.type: sts` (StatefulSet) so each replica gets its own PVC — required when replicas > 1.

## Storage

| Component  | PVC purpose                          | Size            |
|------------|--------------------------------------|-----------------|
| Prometheus | Metrics retention                    | 10Gi            |
| Grafana    | Dashboards, datasources, user config | 1Gi per replica |

Retention: 14 days / 7GB (whichever hits first). Both backed by `nfs-nas` storage class.

## Scrape Config

External scrape targets (outside the cluster) go in `additionalScrapeConfigs` inside `values/prom-stack/values.yaml`:

```yaml
prometheus:
  prometheusSpec:
    additionalScrapeConfigs:
      - job_name: pihole
        static_configs:
          - targets:
            - 192.168.0.180:9617
            - 192.168.0.104:9617
            - 192.168.0.105:9617
            - 192.168.0.202:9617
            - 192.168.0.201:9617
            - 192.168.0.203:9617
            - 192.168.0.204:9617
```

In-cluster apps use `ServiceMonitor` CRs — `kube-prometheus-stack` auto-discovers them. No changes to `values.yaml` needed for those.

For scrape configs that are large or change often, they can live in a separate manifest file under `homelab-argo/values/prom-stack/` and be referenced from `values.yaml` — same ArgoCD app manages it since ArgoCD syncs the whole directory.

## Verify

```bash
kubectl get pods -n monitoring
kubectl get pvc -n monitoring
```


Default creds: `admin` / `prom-operator`

## Later


Grafana is ClusterIP by default. Expose via MetalLB + NPM -- This is later:
```bash
kubectl patch svc prom-stack-grafana -n monitoring -p '{"spec":{"type":"LoadBalancer"}}'
```
- Exporters (node-exporter, pihole, etc.) — add to `additionalScrapeConfigs`
- S3 remote storage for long-term Prometheus retention
- Alertmanager config (stub commented out in values.yaml)
