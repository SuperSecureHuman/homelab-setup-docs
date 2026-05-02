# NFS Provisioner — Migrating to ArgoCD Management

Previously installed manually via `helm install`. This doc describes moving it under ArgoCD so the `homelab-argo` repo becomes the source of truth.

## What goes into homelab-argo

Two files mirror the pattern used by prom-stack:

```
homelab-argo/
  argocd/apps/nfs-provisioner.yaml   ← ArgoCD Application manifest
  values/nfs-provisioner.yaml        ← Helm values (same as 03-storage-nfs/configs/nfs-provisioner-nas.yaml)
```

### argocd/apps/nfs-provisioner.yaml

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nfs-provisioner
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
      chart: nfs-subdir-external-provisioner
      targetRevision: 4.0.18
      helm:
        valueFiles:
          - $values/values/nfs-provisioner.yaml
    - repoURL: "https://github.com/SuperSecureHuman/homelab-argo.git"
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: nfs-provisioner
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

### values/nfs-provisioner.yaml

```yaml
replicaCount: 3

nfs:
  server: 192.168.0.180
  path: /mnt/ssd_mirror/k8s_volume

storageClass:
  name: nfs-nas
  defaultClass: true
  reclaimPolicy: Retain
  archiveOnDelete: false
```

## Migration steps

If the provisioner is already running (installed manually in Chapter 03), adopt it into ArgoCD without reinstalling:

```bash
# 1. Add the Application manifest — ArgoCD will detect the existing Helm release
kubectl apply -f homelab-argo/argocd/apps/nfs-provisioner.yaml

# 2. In the ArgoCD UI: open the nfs-provisioner app → click Sync
#    ArgoCD reconciles state; existing PVCs and StorageClass are unaffected.

# 3. Verify the app goes green
kubectl get application nfs-provisioner -n argocd
```

> ArgoCD adopts existing Helm releases when the release name and namespace match. No downtime, no PVC disruption.

## Verify StorageClass still works after adoption

```bash
kubectl get storageclass          # nfs-nas should still be default
kubectl apply -f 03-storage-nfs/configs/test-pvc.yaml
kubectl get pvc test-pvc          # should bind within ~30 s
kubectl delete pvc test-pvc
```
