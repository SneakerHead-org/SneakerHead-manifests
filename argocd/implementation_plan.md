# ArgoCD App of Apps Manifests for SneakerHead

Create a complete ArgoCD deployment setup using the App of Apps pattern for the SneakerHead microservices platform, with proper sync ordering, environment separation, and database safety.

## Research Findings

### Network Policy & ArgoCD Health Checks

Your health checks are **standard Kubernetes probes** — `httpGet` for microservices and `exec` (pg_isready) for PostgreSQL. These are executed by the **kubelet on each node**, not by ArgoCD. ArgoCD determines resource health by querying the **Kubernetes API** (checking Deployment `.status.conditions`, StatefulSet `.status.readyReplicas`, etc.).

**Conclusion: No additional network policy ingress rules are needed for ArgoCD.** ArgoCD never sends traffic directly to your pods. The existing network policies are sufficient.

### Architecture: App of Apps with Helm Umbrella Chart

Since your Helm chart is an **umbrella chart** (one `Chart.yaml` with all sub-charts as dependencies), each ArgoCD Application will deploy the **same umbrella chart** but with only its specific sub-chart enabled via `values`. This approach lets us leverage sync waves and independent lifecycle management while reusing the existing chart.

## Proposed Changes

The following files will be created under `SneakerHead-manifests/argocd/`:

```
SneakerHead-manifests/
└── argocd/
    ├── appprojects/
    │   ├── sneakerhead-infra.yaml       # AppProject for rbac + network-policies
    │   ├── sneakerhead-data.yaml        # AppProject for databases
    │   └── sneakerhead-apps.yaml        # AppProject for microservices + gateway + frontend
    ├── infra/
    │   ├── rbac-dev.yaml                # Application: rbac (dev, autoSync, wave 0)
    │   ├── rbac-prod.yaml               # Application: rbac (prod, manual, wave 0)
    │   ├── network-policies-dev.yaml    # Application: network-policies (dev, autoSync, wave 0)
    │   └── network-policies-prod.yaml   # Application: network-policies (prod, manual, wave 0)
    ├── databases/
    │   ├── user-postgres-dev.yaml       # Application: user-postgres (dev, manual, wave 1)
    │   ├── user-postgres-prod.yaml      # Application: user-postgres (prod, manual, wave 1)
    │   ├── product-postgres-dev.yaml    # Application: product-postgres (dev, manual, wave 1)
    │   ├── product-postgres-prod.yaml   # Application: product-postgres (prod, manual, wave 1)
    │   ├── order-postgres-dev.yaml      # Application: order-postgres (dev, manual, wave 1)
    │   └── order-postgres-prod.yaml     # Application: order-postgres (prod, manual, wave 1)
    ├── apps/
    │   └── microservices-appset.yaml    # ApplicationSet: all 5 microservices × 2 envs (wave 2)
    └── root-app.yaml                   # Root "App of Apps" — points to argocd/ directory
```

---

### AppProjects (`appprojects/`)

3 AppProject manifests scoped by concern:

| Project | Allowed Namespaces | Allowed Resources |
|---|---|---|
| `sneakerhead-infra` | `sneakerhead-dev`, `sneakerhead-prod` | NetworkPolicy, Role, RoleBinding |
| `sneakerhead-data` | `sneakerhead-dev`, `sneakerhead-prod` | StatefulSet, Service, ConfigMap, Secret, PVC |
| `sneakerhead-apps` | `sneakerhead-dev`, `sneakerhead-prod` | Deployment, Service, ConfigMap, Secret, HPA, Gateway, HTTPRoute |

All projects restricted to the single Git source repo: `https://github.com/SneakerHead-org/SneakerHead-manifests`

---

### Infra Applications (`infra/`)

#### [NEW] rbac-dev.yaml, rbac-prod.yaml
- Sync wave: `0` (applied first)
- Dev: `automated` sync with `selfHeal: true`, `prune: true`
- Prod: manual sync (no `automated` block)
- Deploys umbrella chart with only `rbac.enabled=true`, all others `false`
- Uses environment-specific values file

#### [NEW] network-policies-dev.yaml, network-policies-prod.yaml
- Sync wave: `0`
- Same sync policy pattern as rbac
- Deploys umbrella chart with only `network-policies.enabled=true`

---

### Database Applications (`databases/`)

#### [NEW] {user,product,order}-postgres-{dev,prod}.yaml
- Sync wave: `1` (after infra, before apps)
- **Both dev and prod: manual sync** (autoSync disabled) — prevents accidental data loss
- `Replace: false` explicitly set via sync options
- Deploys umbrella chart with only the specific postgres sub-chart enabled

---

### Microservices ApplicationSet (`apps/`)

#### [NEW] microservices-appset.yaml
- **List generator** iterating over 5 services × 2 environments = 10 Applications
- Sync wave: `2` (after databases)
- Dev: `automated` sync with `selfHeal: true`, `prune: true`
- Prod: manual sync
- Uses Go template to conditionally set `automated` sync policy based on environment
- Services: `frontend`, `gateway`, `order-service`, `product-service`, `user-service`

---

### Root App of Apps (`root-app.yaml`)

#### [NEW] root-app.yaml
- Points to `argocd/` directory in the repo
- Recurses through all subdirectories to discover child Applications/ApplicationSets
- AutoSync enabled to automatically pick up new Application manifests

---

## Design Decisions

> [!IMPORTANT]
> ### Umbrella Chart with Selective Enablement
> Since all sub-charts live under one umbrella `Chart.yaml`, each ArgoCD Application deploys the full umbrella chart but **disables all sub-charts except the one it manages** via Helm parameter overrides (`<chart>.enabled=true/false`). This means each Application gets its own release, sync policy, and health status — which is the whole point of the App of Apps pattern.

> [!WARNING]
> ### Database Safety
> All database Applications (both dev and prod) have autoSync **disabled** and `Replace=false` in sync options. This prevents ArgoCD from automatically applying changes that could destroy StatefulSet PVCs or corrupt data. Database changes must always be manually reviewed and synced.

> [!NOTE]
> ### Sync Wave Ordering
> - **Wave 0**: RBAC + Network Policies (cluster permissions and network isolation must exist first)
> - **Wave 1**: Databases (data tier must be ready before services connect)
> - **Wave 2**: Microservices (depend on both infra and databases)
>
> Sync waves are set via `argocd.argoproj.io/sync-wave` annotations on the Application resources themselves.

## Open Questions

> [!IMPORTANT]
> ### Target Revision
> The manifests currently use `HEAD` as the `targetRevision` for both dev and prod. Would you prefer:
> - `main` branch for dev, tagged releases for prod?
> - Separate branches (e.g., `dev`, `prod`)?
> - `HEAD` for both is fine?

## Verification Plan

### Automated Tests
- Validate all YAML files with `kubectl apply --dry-run=client` against the ArgoCD CRD schemas
- Verify Helm template rendering for each Application's parameter overrides

### Manual Verification
- Apply the root app to ArgoCD and confirm all child Applications appear
- Verify sync wave ordering works as expected
- Confirm database Applications remain in `OutOfSync` state until manually synced
