# ArgoCD — SneakerHead App of Apps

This directory contains all ArgoCD manifests for deploying the SneakerHead microservices platform using the **App of Apps** pattern.

---

## Directory Structure

```
argocd/
├── root-app.yaml                          # Root Application — single entry point
├── README.md                              # This file
├── appprojects/
│   ├── sneakerhead-infra.yaml             # AppProject: RBAC + Network Policies
│   ├── sneakerhead-data.yaml              # AppProject: PostgreSQL databases
│   └── sneakerhead-apps.yaml              # AppProject: Microservices + Gateway
├── infra/                                 # Sync Wave 0 — applied first
│   ├── rbac-dev.yaml
│   ├── rbac-prod.yaml
│   ├── network-policies-dev.yaml
│   └── network-policies-prod.yaml
├── databases/                             # Sync Wave 1 — after infra
│   ├── user-postgres-dev.yaml
│   ├── user-postgres-prod.yaml
│   ├── product-postgres-dev.yaml
│   ├── product-postgres-prod.yaml
│   ├── order-postgres-dev.yaml
│   └── order-postgres-prod.yaml
└── apps/                                  # Sync Wave 2 — after databases
    └── microservices-appset.yaml           # ApplicationSet: 5 services × 2 envs
```

---

## Architecture

### Sync Wave Ordering

| Wave | What | Resources | Rationale |
|------|------|-----------|-----------|
| **0** | Infrastructure | RBAC, Network Policies | Permissions and network isolation must exist before any workloads |
| **1** | Data Tier | user-postgres, product-postgres, order-postgres | Databases must be ready before services connect |
| **2** | Application Tier | frontend, gateway, user-service, product-service, order-service | Depend on both infra and databases |

### Sync Policies

| Category | Dev | Prod |
|----------|-----|------|
| Infra (rbac, network-policies) | autoSync + selfHeal + prune | Manual |
| Databases (all postgres) | **Manual** | **Manual** |
| Microservices (5 services) | autoSync + selfHeal + prune | Manual |

> ⚠️ **Database Safety**: All database Applications have autoSync disabled and `Replace=false` in both environments to prevent accidental StatefulSet/PVC destruction.

### AppProject Scoping

| Project | Allowed Resources | Namespaces |
|---------|-------------------|------------|
| `sneakerhead-infra` | NetworkPolicy, Role, RoleBinding | sneakerhead-dev, sneakerhead-prod |
| `sneakerhead-data` | StatefulSet, Service, ConfigMap, Secret, PVC | sneakerhead-dev, sneakerhead-prod |
| `sneakerhead-apps` | Deployment, Service, ConfigMap, Secret, HPA, Gateway, HTTPRoute | sneakerhead-dev, sneakerhead-prod |

---

## How to Deploy

### Prerequisites

- ArgoCD installed in the `argocd` namespace
- Kubernetes cluster with the namespaces `sneakerhead-dev` and `sneakerhead-prod` (will be auto-created if not present)
- Git repo accessible from ArgoCD: `https://github.com/SneakerHead-org/SneakerHead-manifests`

### 1. Bootstrap — Apply the root app only

```bash
kubectl apply -f argocd/root-app.yaml
```

This single command triggers ArgoCD to recursively discover all child Applications and ApplicationSets.

### 2. What happens automatically

1. ArgoCD creates all 3 AppProjects
2. **Wave 0**: RBAC and Network Policies sync (dev: auto, prod: waits for manual sync)
3. **Wave 1**: Database Applications appear as **OutOfSync** (always manual)
4. **Wave 2**: Microservice Applications appear (dev: auto-syncs, prod: waits)

### 3. Manual sync steps

```bash
# Sync databases for dev
argocd app sync sneakerhead-user-postgres-dev
argocd app sync sneakerhead-product-postgres-dev
argocd app sync sneakerhead-order-postgres-dev

# When ready for prod — sync in order
argocd app sync sneakerhead-rbac-prod
argocd app sync sneakerhead-network-policies-prod
argocd app sync sneakerhead-user-postgres-prod
argocd app sync sneakerhead-product-postgres-prod
argocd app sync sneakerhead-order-postgres-prod
argocd app sync sneakerhead-frontend-prod
argocd app sync sneakerhead-gateway-prod
argocd app sync sneakerhead-user-service-prod
argocd app sync sneakerhead-product-service-prod
argocd app sync sneakerhead-order-service-prod
```

---

## How It Works — Umbrella Chart with Selective Enablement

Each ArgoCD Application deploys the **same umbrella Helm chart** (`helm/sneakerhead/`) but enables only its specific sub-chart via Helm parameters:

```yaml
# Example: user-service Application enables only user-service
parameters:
  - name: frontend.enabled
    value: "false"
  - name: gateway.enabled
    value: "false"
  # ... all others disabled ...
  - name: user-service.enabled    # ← target service LAST (Helm --set order matters)
    value: "true"
```

> **Important**: In the ApplicationSet, the target service enablement is placed **last** in the parameters list. Helm processes `--set` flags left-to-right, and later values override earlier ones.

---

## Network Policy & ArgoCD Health Checks

ArgoCD does **NOT** need network policy ingress rules. Your health checks are:
- **Microservices**: `httpGet` probes (executed by kubelet on nodes)
- **PostgreSQL**: `exec` probes with `pg_isready` (executed inside containers)

ArgoCD determines health by querying the **Kubernetes API server**, not by connecting to pods directly.

---

## Adding Prometheus & Grafana — Future Integration

### What Needs to Change

When you're ready to add Prometheus + Grafana to the ArgoCD setup, the following changes will be required:

#### 1. New AppProject — `sneakerhead-monitoring`

Create `argocd/appprojects/sneakerhead-monitoring.yaml`:
- Allowed namespaces: `monitoring` (or `sneakerhead-monitoring`)
- Allowed resource types: Deployment, StatefulSet, Service, ConfigMap, Secret, ServiceMonitor, PodMonitor, PrometheusRule, DaemonSet, ClusterRole, ClusterRoleBinding, Ingress

#### 2. New Monitoring Applications

Create `argocd/monitoring/` directory with:
- `prometheus-dev.yaml` — Prometheus Application (from `prometheus-community/kube-prometheus-stack` Helm chart or standalone)
- `prometheus-prod.yaml` — Same, manual sync for prod
- `grafana-dev.yaml` — Grafana Application (included in kube-prometheus-stack or standalone)
- `grafana-prod.yaml` — Same, manual sync for prod

#### 3. Sync Wave Placement

- Monitoring should be **Wave 0 or Wave 1** — it should come up early to capture metrics from the start
- If using ServiceMonitors, the CRDs must exist before the microservices that reference them

#### 4. Network Policy Updates

If deploying in the SneakerHead namespace:
- Add ingress rules for Prometheus scraping pods → all app pods on their metrics ports
- Add egress rules for app pods → Prometheus if push-based metrics are used

If deploying in a separate `monitoring` namespace:
- Add cross-namespace NetworkPolicy rules allowing Prometheus to scrape SneakerHead pods
- Update AppProject to allow the monitoring namespace

#### 5. Helm Values Updates

- Add ServiceMonitor/PodMonitor resources to each microservice sub-chart
- Add metrics endpoint configuration to each service's values file
- Add Grafana dashboard ConfigMaps

### Prompt to Add Prometheus & Grafana

Use this prompt when you're ready to integrate:

---

```
I have ArgoCD set up with the App of Apps pattern for my SneakerHead microservices.
My current argocd/ directory is at: SneakerHead-manifests/argocd/

Current setup:
- AppProjects: sneakerhead-infra, sneakerhead-data, sneakerhead-apps
- Sync waves: 0 (infra), 1 (databases), 2 (microservices)
- Environments: dev (autoSync), prod (manual)
- Namespaces: sneakerhead-dev, sneakerhead-prod
- Git repo: https://github.com/SneakerHead-org/SneakerHead-manifests
- Helm umbrella chart: helm/sneakerhead/
- Network policies: default-deny-all with tier-based rules (frontend, backend, data)

I want to add Prometheus and Grafana to this setup. Requirements:

1. Use the kube-prometheus-stack Helm chart (community chart) for both Prometheus and Grafana
2. Deploy into a dedicated `monitoring` namespace
3. Create a new AppProject `sneakerhead-monitoring` scoped to the monitoring namespace
4. Create ArgoCD Application manifests for:
   - kube-prometheus-stack (includes Prometheus, Grafana, Alertmanager, node-exporter)
   - Separate per environment (dev + prod)
5. Sync wave: Deploy monitoring at wave 0 (alongside infra) so it captures metrics from the start
6. Sync policy: autoSync for dev, manual for prod
7. Add ServiceMonitor resources to my existing microservice Helm sub-charts so Prometheus auto-discovers them
8. Update my network policies to allow Prometheus (in monitoring namespace) to scrape all pods in sneakerhead-dev and sneakerhead-prod namespaces
9. Create Grafana dashboard ConfigMaps for:
   - Microservice overview (request rates, latencies, error rates)
   - PostgreSQL database metrics
   - Pod resource utilization (CPU, memory)
10. Configure Prometheus alerting rules for:
    - Pod crash loops
    - High error rates (>5% 5xx)
    - Database connection failures
    - High CPU/memory utilization (>80%)

My microservice ports:
- frontend: 80
- user-service: 8001
- product-service: 8002
- order-service: 8003
- PostgreSQL instances: 5432

Output all new and modified files. Update the ArgoCD README.md with the monitoring section.
```

---

## Troubleshooting

### Application stuck in "Unknown" or "Missing"

Ensure the AppProject allows the resource types the Application is trying to create. Check:
```bash
argocd proj get sneakerhead-apps
```

### Sync wave not respected

Sync waves only apply when the **parent** (root app) syncs. If you manually sync individual apps, waves are ignored.

### Database Application shows "OutOfSync"

This is **expected behavior** — database Applications intentionally have no autoSync. Review the diff in the ArgoCD UI, then manually sync when safe:
```bash
argocd app diff sneakerhead-user-postgres-dev
argocd app sync sneakerhead-user-postgres-dev
```
