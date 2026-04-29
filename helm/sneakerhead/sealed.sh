#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# SneakerHead — Sealed Secrets Generator & Injector
# ═══════════════════════════════════════════════════════════════════════════════
#
# WHAT THIS SCRIPT DOES:
#   1. Fetches the Sealed Secrets controller public certificate from your cluster
#   2. Seals ALL secrets for BOTH namespaces (sneakerhead-dev + sneakerhead-prod)
#      using strict scope (sealed to exact secret-name + namespace)
#   3. Automatically injects the encrypted ciphertext into:
#        • values-dev.yaml  (under each chart's .sealedSecrets block)
#        • values-prod.yaml (under each chart's .sealedSecrets block)
#
# SERVICES HANDLED (6 sub-charts × 2 namespaces = 12 SealedSecret objects):
#   • user-service    → keys: DATABASE_URL, JWT_SECRET
#   • product-service → keys: DATABASE_URL, JWT_SECRET
#   • order-service   → keys: DATABASE_URL, JWT_SECRET
#   • user-postgres   → keys: POSTGRES_USER, POSTGRES_PASSWORD
#   • product-postgres→ keys: POSTGRES_USER, POSTGRES_PASSWORD
#   • order-postgres  → keys: POSTGRES_USER, POSTGRES_PASSWORD
#
# PRE-REQUISITES (must be available in PATH on your cluster node):
#   • kubectl  — with valid kubeconfig pointing to your cluster
#   • kubeseal — Bitnami Sealed Secrets CLI
#   • python3  — for YAML injection (always present on Linux)
#   • yq       — (optional, preferred) go-based yq for comment-preserving injection
#
# USAGE:
#   chmod +x generate-secrets.sh
#   ./generate-secrets.sh
#
# Then push the updated values files:
#   cd ../../..   (go to SneakerHead-manifests repo root)
#   git add helm/sneakerhead/values-dev.yaml helm/sneakerhead/values-prod.yaml
#   git commit -m "chore: regenerate sealed secrets"
#   git push
#
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ───────────────────────────────────────────────────────────────────────────────
# SECTION 1: ✏️  EDIT THESE SECRETS — Fill in ALL values before running
# ───────────────────────────────────────────────────────────────────────────────

# ── JWT Signing Key ────────────────────────────────────────────────────────────
# Shared across user-service, product-service, order-service in BOTH envs.
JWT_SECRET="your-super-secret-jwt-key-change-in-production"

# ── PostgreSQL — User Service Database ────────────────────────────────────────
POSTGRES_USER_DB_USER="sneaker"
POSTGRES_USER_DB_PASSWORD="sneakerpass123"

# ── PostgreSQL — Product Service Database ─────────────────────────────────────
POSTGRES_PRODUCT_DB_USER="sneaker"
POSTGRES_PRODUCT_DB_PASSWORD="sneakerpass123"

# ── PostgreSQL — Order Service Database ───────────────────────────────────────
POSTGRES_ORDER_DB_USER="sneaker"
POSTGRES_ORDER_DB_PASSWORD="sneakerpass123"

# ───────────────────────────────────────────────────────────────────────────────
# SECTION 2: INFRASTRUCTURE CONFIG — Only change if your setup differs
# ───────────────────────────────────────────────────────────────────────────────

# Bitnami Sealed Secrets controller location
# Verified from: kubectl get pods -n sealed-secrets
# Pod: sealed-secrets-controller-76db8bfb6-d74hc → Deployment: sealed-secrets-controller
CONTROLLER_NAME="sealed-secrets-controller"
CONTROLLER_NAMESPACE="sealed-secrets"

# Application namespaces (MUST match global.namespace in values files)
DEV_NAMESPACE="sneakerhead-dev"
PROD_NAMESPACE="sneakerhead-prod"

# Database service hostnames (Kubernetes service names inside each namespace)
# These are the exact hostnames the services use to connect
USER_DB_HOST="user-postgres"
PRODUCT_DB_HOST="product-postgres"
ORDER_DB_HOST="order-postgres"

# Database names (must match POSTGRES_DB in configmap config section)
USER_DB_NAME="userdb"
PRODUCT_DB_NAME="productdb"
ORDER_DB_NAME="orderdb"

# Database URL driver scheme
# IMPORTANT: The Python async services use SQLAlchemy with asyncpg driver.
# The scheme MUST be postgresql+asyncpg:// — NOT postgresql://
DB_SCHEME="postgresql+asyncpg"

# ═══════════════════════════════════════════════════════════════════════════════
# INTERNAL: Nothing below this line needs to be edited
# ═══════════════════════════════════════════════════════════════════════════════

# Resolve paths relative to this script's location
# Script is at:  SneakerHead-manifests/helm/sneakerhead/generate-secrets.sh
# SCRIPT_DIR  =  <abs>/SneakerHead-manifests/helm/sneakerhead
# REPO_ROOT   =  <abs>/SneakerHead-manifests   (two levels up)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VALUES_DEV="${SCRIPT_DIR}/values-dev.yaml"
VALUES_PROD="${SCRIPT_DIR}/values-prod.yaml"
CERT_FILE="${SCRIPT_DIR}/.pub_cert.pem"

# Temp directory for intermediate YAML files — cleaned up on exit
WORK_DIR="$(mktemp -d /tmp/sneakerhead-sealing-XXXXXX)"
trap 'rm -rf "${WORK_DIR}" "${CERT_FILE}"' EXIT

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_ok()      { echo -e "${GREEN}[  OK]${RESET}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error()   { echo -e "${RED}[FAIL]${RESET}  $*" >&2; }
log_section() { echo -e "\n${BOLD}${CYAN}══════ $* ══════${RESET}"; }

# ── Validate that placeholder values have been replaced ───────────────────────
validate_secrets() {
  log_section "Validating secret values"
  local has_placeholder=false

  if [[ -z "${JWT_SECRET}" ]]; then
    log_error "JWT_SECRET is empty. Please edit this script."
    has_placeholder=true
  fi
  if [[ -z "${POSTGRES_USER_DB_PASSWORD}" ]]; then
    log_error "POSTGRES_USER_DB_PASSWORD is empty. Please edit this script."
    has_placeholder=true
  fi
  if [[ -z "${POSTGRES_PRODUCT_DB_PASSWORD}" ]]; then
    log_error "POSTGRES_PRODUCT_DB_PASSWORD is empty. Please edit this script."
    has_placeholder=true
  fi
  if [[ -z "${POSTGRES_ORDER_DB_PASSWORD}" ]]; then
    log_error "POSTGRES_ORDER_DB_PASSWORD is empty. Please edit this script."
    has_placeholder=true
  fi

  if [[ "${has_placeholder}" == "true" ]]; then
    echo -e "\n${RED}Aborting: one or more secret values are empty.${RESET}"
    exit 1
  fi

  # Show what will be sealed (masked passwords)
  log_ok "All secret values are set."
  log_info "JWT_SECRET      : ${JWT_SECRET:0:8}...(masked)"
  log_info "DB scheme       : ${DB_SCHEME}"
  log_info "Postgres user   : ${POSTGRES_USER_DB_USER} / ${POSTGRES_PRODUCT_DB_USER} / ${POSTGRES_ORDER_DB_USER}"
  log_info "Postgres pass   : ${POSTGRES_USER_DB_PASSWORD:0:4}...(masked)"
}

# ── Pre-flight checks ─────────────────────────────────────────────────────────
preflight_checks() {
  log_section "Pre-flight checks"

  for cmd in kubectl kubeseal python3; do
    if ! command -v "${cmd}" &>/dev/null; then
      log_error "'${cmd}' not found in PATH. Please install it."
      exit 1
    fi
    log_ok "'${cmd}' found: $(command -v "${cmd}")"
  done

  if ! command -v yq &>/dev/null; then
    log_warn "'yq' not found — will use python3 for YAML injection (comments in values files may be lost)."
    YQ_AVAILABLE=false
  else
    YQ_VERSION="$(yq --version 2>&1 | head -1)"
    log_ok "'yq' found: ${YQ_VERSION}"
    YQ_AVAILABLE=true
  fi

  if [[ ! -f "${VALUES_DEV}" ]]; then
    log_error "values-dev.yaml not found at: ${VALUES_DEV}"
    exit 1
  fi
  log_ok "values-dev.yaml found."

  if [[ ! -f "${VALUES_PROD}" ]]; then
    log_error "values-prod.yaml not found at: ${VALUES_PROD}"
    exit 1
  fi
  log_ok "values-prod.yaml found."

  # Verify kubectl can reach the cluster
  if ! kubectl cluster-info &>/dev/null; then
    log_error "kubectl cannot reach the cluster. Check your kubeconfig."
    exit 1
  fi
  log_ok "kubectl cluster connection verified."

  # ── Verify / Auto-discover the Sealed Secrets controller ─────────────────────
  # PRIORITY: configured values in SECTION 2 are checked FIRST.
  # Auto-discovery only runs if the configured deployment is not found.
  # This prevents accidentally picking up a controller in the wrong namespace.
  log_info "Verifying Sealed Secrets controller: name='${CONTROLLER_NAME}' ns='${CONTROLLER_NAMESPACE}'"

  if kubectl get deployment "${CONTROLLER_NAME}" -n "${CONTROLLER_NAMESPACE}" &>/dev/null; then
    log_ok "Sealed Secrets controller confirmed: '${CONTROLLER_NAME}' in '${CONTROLLER_NAMESPACE}'"
  else
    log_warn "Configured controller '${CONTROLLER_NAME}' not found in '${CONTROLLER_NAMESPACE}'."
    log_warn "Running auto-discovery across all namespaces..."

    local discovered_ns=""
    local discovered_name=""

    # Search all namespaces — prefer the configured namespace if multiple matches exist
    while IFS= read -r line; do
      local ns name
      ns="$(echo "${line}"   | awk '{print $1}')"
      name="$(echo "${line}" | awk '{print $2}')"
      if [[ "${name}" == *"sealed"* ]]; then
        # Prefer match in the configured namespace
        if [[ "${ns}" == "${CONTROLLER_NAMESPACE}" ]]; then
          discovered_ns="${ns}"
          discovered_name="${name}"
          break
        elif [[ -z "${discovered_ns}" ]]; then
          # Accept first match as fallback, but keep looking
          discovered_ns="${ns}"
          discovered_name="${name}"
        fi
      fi
    done < <(kubectl get deployments --all-namespaces --no-headers 2>/dev/null)

    if [[ -n "${discovered_ns}" && -n "${discovered_name}" ]]; then
      log_ok "Auto-discovered controller: deployment='${discovered_name}' namespace='${discovered_ns}'"
      CONTROLLER_NAME="${discovered_name}"
      CONTROLLER_NAMESPACE="${discovered_ns}"
    else
      log_error "Could not find a Sealed Secrets controller anywhere in the cluster."
      log_error "Run: kubectl get deployments --all-namespaces | grep -i sealed"
      log_error "Then set CONTROLLER_NAME and CONTROLLER_NAMESPACE in SECTION 2."
      exit 1
    fi
  fi
}

# ── Fetch the controller's public certificate ─────────────────────────────────
fetch_cert() {
  log_section "Fetching Sealed Secrets public certificate"

  log_info "Using controller: name='${CONTROLLER_NAME}'  namespace='${CONTROLLER_NAMESPACE}'"

  if ! kubeseal \
    --controller-name="${CONTROLLER_NAME}" \
    --controller-namespace="${CONTROLLER_NAMESPACE}" \
    --fetch-cert \
    > "${CERT_FILE}" 2>/tmp/kubeseal_err.txt; then

    log_error "kubeseal --fetch-cert failed. Error output:"
    cat /tmp/kubeseal_err.txt >&2
    echo ""
    log_error "Troubleshooting: find the controller by running:"
    log_error "  kubectl get deployments --all-namespaces | grep -i sealed"
    log_error "  kubectl get services    --all-namespaces | grep -i sealed"
    log_error "Then update CONTROLLER_NAME and CONTROLLER_NAMESPACE in SECTION 2."
    exit 1
  fi

  if [[ ! -s "${CERT_FILE}" ]]; then
    log_error "Certificate file is empty. The controller may not be reachable."
    exit 1
  fi

  log_ok "Certificate fetched successfully."
  CERT_FINGERPRINT="$(openssl x509 -in "${CERT_FILE}" -fingerprint -noout 2>/dev/null || echo 'N/A')"
  log_info "Cert fingerprint : ${CERT_FINGERPRINT}"
}

# ── Core sealing function ─────────────────────────────────────────────────────
# Usage: seal_value <secret_name> <namespace> <key> <value>
# Returns: encrypted ciphertext (written to WORK_DIR/sealed_output.txt)
seal_value() {
  local secret_name="$1"
  local namespace="$2"
  local key="$3"
  local value="$4"

  local tmp_secret="${WORK_DIR}/plain-${secret_name}-${namespace}-${key}.yaml"
  local tmp_sealed="${WORK_DIR}/sealed-${secret_name}-${namespace}-${key}.yaml"

  # Create a dry-run Secret manifest with exactly one key
  kubectl create secret generic "${secret_name}" \
    --namespace="${namespace}" \
    --from-literal="${key}=${value}" \
    --dry-run=client \
    -o yaml > "${tmp_secret}"

  # Seal it against the fetched cert with strict scope
  # strict = sealed to BOTH the secret name AND namespace
  kubeseal \
    --cert="${CERT_FILE}" \
    --scope=strict \
    --format=yaml \
    < "${tmp_secret}" \
    > "${tmp_sealed}"

  # Extract just the encrypted ciphertext for this specific key
  python3 - "${tmp_sealed}" "${key}" <<'PYEOF'
import yaml, sys

with open(sys.argv[1], 'r') as f:
    sealed = yaml.safe_load(f)

key = sys.argv[2]
encrypted = sealed['spec']['encryptedData'][key]
print(encrypted, end='')
PYEOF
}

# ── YAML injection function ────────────────────────────────────────────────────
# Injects an encrypted value into the correct sealedSecrets block in a values file.
# Usage: inject_sealed_value <values_file> <chart_key> <secret_key> <encrypted_value>
# chart_key examples: "user-service", "product-postgres"
inject_sealed_value() {
  local values_file="$1"
  local chart_key="$2"
  local secret_key="$3"
  local encrypted_value="$4"

  # Write the encrypted value to a temp file to avoid shell quoting/escaping issues
  local val_file="${WORK_DIR}/val-${chart_key//[^a-z]/-}-${secret_key}.txt"
  printf '%s' "${encrypted_value}" > "${val_file}"

  if [[ "${YQ_AVAILABLE}" == "true" ]]; then
    # yq v4 preserves YAML comments; keys with hyphens require bracket notation
    yq e ".\"${chart_key}\".sealedSecrets.\"${secret_key}\" = \"$(cat "${val_file}")\"" \
      -i "${values_file}"
  else
    # python3 fallback — rewrites YAML (comments are lost on first run)
    python3 - "${values_file}" "${chart_key}" "${secret_key}" "${val_file}" <<'PYEOF'
import yaml, sys

values_file  = sys.argv[1]
chart_key    = sys.argv[2]
secret_key   = sys.argv[3]
val_file     = sys.argv[4]

with open(val_file, 'r') as f:
    encrypted_value = f.read().strip()

with open(values_file, 'r') as f:
    data = yaml.safe_load(f)

# Ensure the nested path exists
if chart_key not in data or data[chart_key] is None:
    data[chart_key] = {}
if 'sealedSecrets' not in data[chart_key] or data[chart_key]['sealedSecrets'] is None:
    data[chart_key]['sealedSecrets'] = {}

data[chart_key]['sealedSecrets'][secret_key] = encrypted_value

with open(values_file, 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True,
              sort_keys=False, width=10000)
PYEOF
  fi

  log_ok "  ${chart_key}.sealedSecrets.${secret_key} → injected"
}

# ── Seal + inject a complete set of secrets for one environment ───────────────
# Usage: process_environment <env_label> <namespace> <values_file>
process_environment() {
  local env_label="$1"
  local namespace="$2"
  local values_file="$3"

  log_section "Processing: ${env_label} (namespace: ${namespace})"

  # Construct database URLs for this environment
  # Uses postgresql+asyncpg:// scheme — required by SQLAlchemy async engine
  local user_db_url="${DB_SCHEME}://${POSTGRES_USER_DB_USER}:${POSTGRES_USER_DB_PASSWORD}@${USER_DB_HOST}:5432/${USER_DB_NAME}"
  local product_db_url="${DB_SCHEME}://${POSTGRES_PRODUCT_DB_USER}:${POSTGRES_PRODUCT_DB_PASSWORD}@${PRODUCT_DB_HOST}:5432/${PRODUCT_DB_NAME}"
  local order_db_url="${DB_SCHEME}://${POSTGRES_ORDER_DB_USER}:${POSTGRES_ORDER_DB_PASSWORD}@${ORDER_DB_HOST}:5432/${ORDER_DB_NAME}"

  # ── user-service ─────────────────────────────────────────────────────────────
  log_info "Sealing user-service secrets..."
  VAL="$(seal_value "user-service-secret" "${namespace}" "DATABASE_URL" "${user_db_url}")"
  inject_sealed_value "${values_file}" "user-service" "DATABASE_URL" "${VAL}"

  VAL="$(seal_value "user-service-secret" "${namespace}" "JWT_SECRET" "${JWT_SECRET}")"
  inject_sealed_value "${values_file}" "user-service" "JWT_SECRET" "${VAL}"

  # ── product-service ───────────────────────────────────────────────────────────
  log_info "Sealing product-service secrets..."
  VAL="$(seal_value "product-service-secret" "${namespace}" "DATABASE_URL" "${product_db_url}")"
  inject_sealed_value "${values_file}" "product-service" "DATABASE_URL" "${VAL}"

  VAL="$(seal_value "product-service-secret" "${namespace}" "JWT_SECRET" "${JWT_SECRET}")"
  inject_sealed_value "${values_file}" "product-service" "JWT_SECRET" "${VAL}"

  # ── order-service ─────────────────────────────────────────────────────────────
  log_info "Sealing order-service secrets..."
  VAL="$(seal_value "order-service-secret" "${namespace}" "DATABASE_URL" "${order_db_url}")"
  inject_sealed_value "${values_file}" "order-service" "DATABASE_URL" "${VAL}"

  VAL="$(seal_value "order-service-secret" "${namespace}" "JWT_SECRET" "${JWT_SECRET}")"
  inject_sealed_value "${values_file}" "order-service" "JWT_SECRET" "${VAL}"

  # ── user-postgres ─────────────────────────────────────────────────────────────
  log_info "Sealing user-postgres secrets..."
  VAL="$(seal_value "user-postgres-secret" "${namespace}" "POSTGRES_USER" "${POSTGRES_USER_DB_USER}")"
  inject_sealed_value "${values_file}" "user-postgres" "POSTGRES_USER" "${VAL}"

  VAL="$(seal_value "user-postgres-secret" "${namespace}" "POSTGRES_PASSWORD" "${POSTGRES_USER_DB_PASSWORD}")"
  inject_sealed_value "${values_file}" "user-postgres" "POSTGRES_PASSWORD" "${VAL}"

  # ── product-postgres ──────────────────────────────────────────────────────────
  log_info "Sealing product-postgres secrets..."
  VAL="$(seal_value "product-postgres-secret" "${namespace}" "POSTGRES_USER" "${POSTGRES_PRODUCT_DB_USER}")"
  inject_sealed_value "${values_file}" "product-postgres" "POSTGRES_USER" "${VAL}"

  VAL="$(seal_value "product-postgres-secret" "${namespace}" "POSTGRES_PASSWORD" "${POSTGRES_PRODUCT_DB_PASSWORD}")"
  inject_sealed_value "${values_file}" "product-postgres" "POSTGRES_PASSWORD" "${VAL}"

  # ── order-postgres ────────────────────────────────────────────────────────────
  log_info "Sealing order-postgres secrets..."
  VAL="$(seal_value "order-postgres-secret" "${namespace}" "POSTGRES_USER" "${POSTGRES_ORDER_DB_USER}")"
  inject_sealed_value "${values_file}" "order-postgres" "POSTGRES_USER" "${VAL}"

  VAL="$(seal_value "order-postgres-secret" "${namespace}" "POSTGRES_PASSWORD" "${POSTGRES_ORDER_DB_PASSWORD}")"
  inject_sealed_value "${values_file}" "order-postgres" "POSTGRES_PASSWORD" "${VAL}"

  log_ok "All secrets for ${env_label} (${namespace}) sealed and injected into $(basename "${values_file}")."
}

# ── Final summary ──────────────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗"
  echo -e "║   ✅  Sealed Secrets Generation Complete!            ║"
  echo -e "╚══════════════════════════════════════════════════════╝${RESET}"
  echo ""

  # ── Path layout (so user can verify everything resolved correctly) ───────────
  echo -e "${BOLD}Resolved paths:${RESET}"
  echo -e "  ${CYAN}Repo root  : ${REPO_ROOT}${RESET}"
  echo -e "  ${CYAN}Script dir : ${SCRIPT_DIR}${RESET}"
  echo -e "  ${CYAN}DEV values : ${VALUES_DEV}${RESET}"
  echo -e "  ${CYAN}PROD values: ${VALUES_PROD}${RESET}"
  echo ""

  echo -e "${BOLD}Updated files:${RESET}"
  echo -e "  ${GREEN}• helm/sneakerhead/values-dev.yaml${RESET}"
  echo -e "  ${GREEN}• helm/sneakerhead/values-prod.yaml${RESET}"
  echo ""

  echo -e "${BOLD}Next steps — push the updated values files to GitHub:${RESET}"
  echo ""
  echo -e "  ${YELLOW}# The script already ran from inside the repo.${RESET}"
  echo -e "  ${YELLOW}# Just navigate to the repo root and push:${RESET}"
  echo -e "  cd \"${REPO_ROOT}\""
  echo ""
  echo -e "  ${YELLOW}# Stage ONLY the values files (never commit plaintext secrets!)${RESET}"
  echo -e "  git add helm/sneakerhead/values-dev.yaml helm/sneakerhead/values-prod.yaml"
  echo -e "  git commit -m \"chore: regenerate sealed secrets [skip ci]\""
  echo -e "  git push"
  echo ""
  echo -e "  ${YELLOW}# ArgoCD will pick up the changes and sync automatically.${RESET}"
  echo -e "  ${YELLOW}# Verify SealedSecrets were decrypted by the controller:${RESET}"
  echo -e "  kubectl get sealedsecrets -n sneakerhead-dev"
  echo -e "  kubectl get sealedsecrets -n sneakerhead-prod"
  echo -e "  kubectl get secrets     -n sneakerhead-dev"
  echo -e "  kubectl get secrets     -n sneakerhead-prod"
  echo ""
  echo -e "${RED}⚠️  SECURITY REMINDER: Do NOT commit this script with real${RESET}"
  echo -e "${RED}   secret values filled in. Clear SECTION 1 after use.${RESET}"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
  echo -e "${BOLD}${CYAN}"
  echo "  ╔═══════════════════════════════════════════════════╗"
  echo "  ║     SneakerHead — Sealed Secrets Generator        ║"
  echo "  ║     Namespaces: dev + prod | Charts: 6            ║"
  echo "  ╚═══════════════════════════════════════════════════╝"
  echo -e "${RESET}"

  validate_secrets
  preflight_checks
  fetch_cert

  # Process DEV namespace → values-dev.yaml
  process_environment "DEV" "${DEV_NAMESPACE}" "${VALUES_DEV}"

  # Process PROD namespace → values-prod.yaml
  process_environment "PROD" "${PROD_NAMESPACE}" "${VALUES_PROD}"

  print_summary
}

main "$@"
