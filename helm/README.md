# SneakerHead Helm Deployment Guide

## Prerequisites

1. **Kubernetes cluster** running (kubeadm v1.30+)
2. **Helm 3** installed on your local machine or control plane node:
   ```bash
   curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
   helm version
   ```
3. **kgateway** installed (`GatewayClass: kgateway`)
4. **NFS provisioner** configured (`storageClassName: nfs-client`)
5. **Calico** or similar CNI with NetworkPolicy support

---

## Quick Start

### Step 1: Clone and Navigate
```bash
cd SneakerHead-manifests/helm/sneakerhead
```

### Step 2: Update Dependencies
```bash
helm dependency update .
```
> This resolves all 10 sub-chart dependencies defined in `Chart.yaml`.

### Step 3: Dry Run (Preview)
Always preview before deploying:
```bash
# Dev
helm template sneakerhead-dev . -f values-dev.yaml

# Prod
helm template sneakerhead-prod . -f values-prod.yaml
```
# Note: you should have namespaces created before running the deploy command (kubectl create namespace sneakerhead-dev, kubectl create namespace sneakerhead-prod)

### Step 4: Deploy Dev Environment
```bash
helm install sneakerhead-dev . \
  -f values-dev.yaml \
  -n sneakerhead-dev 
```

### Step 5: Deploy Prod Environment
```bash
helm install sneakerhead-prod . \
  -f values-prod.yaml \
  -n sneakerhead-prod 
```

### Step 6: Verify Deployment
```bash
# Check all pods
kubectl get pods -n sneakerhead-dev
kubectl get pods -n sneakerhead-prod

# Check services
kubectl get svc -n sneakerhead-dev
kubectl get svc -n sneakerhead-prod

# Check gateway
kubectl get gateway -A
kubectl get httproute -A

# Get gateway NodePort
kubectl get svc sneakerhead-gateway -n sneakerhead-dev -o jsonpath='{.spec.ports[0].nodePort}'
```

---

## Day-to-Day Operations

### Upgrade (After Changing Values)
```bash
helm upgrade sneakerhead-dev . -f values-dev.yaml -n sneakerhead-dev
helm upgrade sneakerhead-prod . -f values-prod.yaml -n sneakerhead-prod
```

### Install or Upgrade (Idempotent)
```bash
helm upgrade --install sneakerhead-dev . -f values-dev.yaml -n sneakerhead-dev --create-namespace
```

### Rollback
```bash
# View release history
helm history sneakerhead-dev -n sneakerhead-dev

# Rollback to previous revision
helm rollback sneakerhead-dev 1 -n sneakerhead-dev
```

### Uninstall
```bash
helm uninstall sneakerhead-dev -n sneakerhead-dev
helm uninstall sneakerhead-prod -n sneakerhead-prod
```

> **Note:** PVCs created by StatefulSets are NOT deleted on uninstall. To fully clean up:
> ```bash
> kubectl delete pvc --all -n sneakerhead-dev
> kubectl delete pvc --all -n sneakerhead-prod
> ```

### Check Release Status
```bash
helm list -A
helm status sneakerhead-dev -n sneakerhead-dev
```

---

## Chart Structure

```
helm/sneakerhead/
├── Chart.yaml              # Umbrella chart with 10 sub-chart dependencies
├── values-dev.yaml         # Dev environment values (single source of truth)
├── values-prod.yaml        # Prod environment values (single source of truth)
├── templates/
│   └── namespace.yaml      # Namespace resource
└── charts/
    ├── frontend/           # ConfigMap, Deployment, Service, HPA
    ├── user-service/       # ConfigMap, Secret, Deployment, Service
    ├── product-service/    # ConfigMap, Secret, Deployment, Service
    ├── order-service/      # ConfigMap, Secret, Deployment, Service
    ├── user-postgres/      # ConfigMap, Secret, StatefulSet, Service
    ├── product-postgres/   # ConfigMap, Secret, StatefulSet, Service
    ├── order-postgres/     # ConfigMap, Secret, StatefulSet, Service
    ├── gateway/            # Gateway CRD, HTTPRoutes
    ├── network-policies/   # All 5 network policies
    └── rbac/               # Role, RoleBinding
```

---

## Customization

All configuration lives in `values-dev.yaml` and `values-prod.yaml`. Common changes:

### Change Image Tag
```yaml
# In values-dev.yaml or values-prod.yaml
user-service:
  image:
    tag: v2.0.0
```
Then: `helm upgrade sneakerhead-dev . -f values-dev.yaml -n sneakerhead-dev`

### Scale Replicas
```yaml
frontend:
  replicaCount: 4
```

### Change Database Storage
```yaml
user-postgres:
  storage:
    size: 10Gi
```

### Disable a Sub-chart
```yaml
rbac:
  enabled: false
```

---

## Troubleshooting

```bash
# Debug a failed install
helm install sneakerhead-dev . -f values-dev.yaml -n sneakerhead-dev --debug --dry-run

# Check pod logs
kubectl logs -l app=order-service -n sneakerhead-dev --tail=50

# Describe a failing pod
kubectl describe pod -l app=product-service -n sneakerhead-dev

# Check events
kubectl get events -n sneakerhead-dev --sort-by='.lastTimestamp'
```
