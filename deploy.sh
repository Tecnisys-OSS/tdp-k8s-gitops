#!/bin/bash

# TDP GitOps Deployment Script
# This script reads variables from variables.env and replaces them in YAML files

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARIABLES_FILE="${SCRIPT_DIR}/variables.env"
BACKUP_DIR="${SCRIPT_DIR}/.backup"
COMMON_DIR="${SCRIPT_DIR}/common"
AVAILABLE_DIR="${SCRIPT_DIR}/available"
CURRENT_DIR="${SCRIPT_DIR}/current"

# Set from the command line (see main)
DOMAIN_OVERRIDE=""       # -d/--domain: overrides TDP_DOMAIN from the variables file
EXPOSE_OVERRIDE=""       # -e/--expose: overrides TDP_EXPOSE from the variables file
FORCE_VALUES=false       # --force: overwrite existing current/<component>/values*.yaml

# Variables substituted in templates besides the ones declared in the variables file
OPTIONAL_VARS=(TDP_DOMAIN TDP_INGRESS_CLASS TDP_STORAGE_CLASS
    TDP_INGRESS_ENABLED TDP_GATEWAYAPI_ENABLED TDP_GATEWAY_NAME TDP_GATEWAY_NAMESPACE
    TDP_OPENMETADATA_MYSQL_ENABLED TDP_OPENMETADATA_POSTGRESQL_ENABLED)

# Component passwords substituted in available/*/values*.yaml. An empty or
# missing one falls back to TDP_DEFAULT_PASSWORD (see resolve_passwords).
PASSWORD_VARS=(TDP_AIRFLOW_ADMIN_PASSWORD TDP_AIRFLOW_DB_PASSWORD
    TDP_CLICKHOUSE_TRINO_PASSWORD TDP_CLICKHOUSE_SUPERSET_PASSWORD
    TDP_CLOUDBEAVER_ADMIN_PASSWORD TDP_HIVE_DB_PASSWORD TDP_JUPYTER_ADMIN_PASSWORD
    TDP_KAFKA_UI_ADMIN_PASSWORD TDP_RANGER_ADMIN_PASSWORD TDP_RANGER_DB_PASSWORD
    TDP_SUPERSET_ADMIN_PASSWORD TDP_SUPERSET_DB_PASSWORD)
SHIPPED_DEFAULT_PASSWORD='ChangeMe!T3c'
# Secret keys substituted in available/*/values*.yaml (see resolve_secret_key)
SECRET_KEY_VARS=(TDP_SUPERSET_SECRET_KEY TDP_OZONE_KDC_MASTER_PASSWORD)

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if required tools are installed
# skip_kubectl=true  → skip kubectl check (render-only mode)
# need_helm=true     → also require helm (--install mode)
check_dependencies() {
    local skip_kubectl="${1:-false}"
    local need_helm="${2:-false}"
    local missing_tools=()
    
    if [ "$skip_kubectl" != "true" ] && ! command -v kubectl &> /dev/null; then
        missing_tools+=("kubectl")
    fi
    
    if ! command -v envsubst &> /dev/null; then
        missing_tools+=("envsubst")
    fi

    if [ "$need_helm" = "true" ] && ! command -v helm &> /dev/null; then
        missing_tools+=("helm")
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        print_info "Please install the missing tools and try again."
        exit 1
    fi
}

# Resolve a path from the variables file: relative paths are relative to that file
resolve_path() {
    local path="$1"
    [ -z "$path" ] && return 0
    case "$path" in
        /*) echo "$path" ;;
        *)  echo "$(cd "$(dirname "$VARIABLES_FILE")" && pwd)/$path" ;;
    esac
}

# Function to validate variables file
validate_variables_file() {
    if [ ! -f "$VARIABLES_FILE" ]; then
        print_error "Variables file not found: $VARIABLES_FILE"
        print_info "Please copy variables.env.example to variables.env and customize it."
        exit 1
    fi
    
    print_info "Reading variables from: $VARIABLES_FILE"

    # Source (and export, for envsubst) the variables file with error handling
    set -a
    if ! source "$VARIABLES_FILE"; then
        set +a
        print_error "Failed to source variables file"
        exit 1
    fi
    set +a

    # Optional variables, so an older variables.env.local keeps working.
    # -d/--domain wins over the file.
    if [ -n "$DOMAIN_OVERRIDE" ]; then
        TDP_DOMAIN="$DOMAIN_OVERRIDE"
    elif [ -z "${TDP_DOMAIN:-}" ]; then
        TDP_DOMAIN="tdp.local"
        print_warning "TDP_DOMAIN not set — using ${TDP_DOMAIN}"
    fi
    export TDP_DOMAIN
    export TDP_INGRESS_CLASS="${TDP_INGRESS_CLASS:-}"
    export TDP_STORAGE_CLASS="${TDP_STORAGE_CLASS:-}"
    TDP_LICENSE_NAMESPACE="${TDP_LICENSE_NAMESPACE:-tdp-system}"
    print_info "Ingress/Gateway API domain: ${TDP_DOMAIN}"

    # Exposure: TDP_EXPOSE (or -e/--expose) → the mutually exclusive
    # TDP-Settings.gateway.{ingress,gatewayApi}.enabled switches in values-gitops.yaml
    [ -n "$EXPOSE_OVERRIDE" ] && TDP_EXPOSE="$EXPOSE_OVERRIDE"
    case "$(echo "${TDP_EXPOSE:-none}" | tr '[:upper:]' '[:lower:]')" in
        ingress)    TDP_INGRESS_ENABLED=true;  TDP_GATEWAYAPI_ENABLED=false ;;
        gatewayapi) TDP_INGRESS_ENABLED=false; TDP_GATEWAYAPI_ENABLED=true ;;
        none|"")    TDP_INGRESS_ENABLED=false; TDP_GATEWAYAPI_ENABLED=false ;;
        *)
            print_error "TDP_EXPOSE must be ingress, gatewayapi or none (got: ${TDP_EXPOSE})"
            exit 1
            ;;
    esac
    export TDP_INGRESS_ENABLED TDP_GATEWAYAPI_ENABLED
    export TDP_GATEWAY_NAME="${TDP_GATEWAY_NAME:-}"
    export TDP_GATEWAY_NAMESPACE="${TDP_GATEWAY_NAMESPACE:-}"
    if [ "$TDP_GATEWAYAPI_ENABLED" = "true" ] && [ -z "$TDP_GATEWAY_NAME" ]; then
        print_error "Gateway API exposure needs TDP_GATEWAY_NAME (the Gateway the HTTPRoutes attach to)"
        exit 1
    fi
    print_info "Exposure: ${TDP_EXPOSE:-none}$([ "$TDP_GATEWAYAPI_ENABLED" = "true" ] && echo " (Gateway ${TDP_GATEWAY_NAMESPACE:+$TDP_GATEWAY_NAMESPACE/}${TDP_GATEWAY_NAME})")"

    # OpenMetadata database: TDP_OPENMETADATA_DATABASE → the mutually exclusive
    # global.TDP-Settings.database.{mysql,postgresql}.enabled switches in its values-gitops.yaml
    case "$(echo "${TDP_OPENMETADATA_DATABASE:-mysql}" | tr '[:upper:]' '[:lower:]')" in
        mysql|"")   TDP_OPENMETADATA_MYSQL_ENABLED=true;  TDP_OPENMETADATA_POSTGRESQL_ENABLED=false ;;
        postgresql) TDP_OPENMETADATA_MYSQL_ENABLED=false; TDP_OPENMETADATA_POSTGRESQL_ENABLED=true ;;
        *)
            print_error "TDP_OPENMETADATA_DATABASE must be mysql or postgresql (got: ${TDP_OPENMETADATA_DATABASE})"
            exit 1
            ;;
    esac
    export TDP_OPENMETADATA_MYSQL_ENABLED TDP_OPENMETADATA_POSTGRESQL_ENABLED

    # Ozone security: TDP_OZONE_SECURITY=true renders the values-ozone-security.yaml
    # overlays (see enable-ozone-security.sh)
    TDP_OZONE_SECURITY="$(echo "${TDP_OZONE_SECURITY:-false}" | tr '[:upper:]' '[:lower:]')"
    case "$TDP_OZONE_SECURITY" in
        true|false) ;;
        *)
            print_error "TDP_OZONE_SECURITY must be true or false (got: ${TDP_OZONE_SECURITY})"
            exit 1
            ;;
    esac
    print_info "Ozone security: ${TDP_OZONE_SECURITY}"

    # Validate required variables
    local required_vars=(
        "ARGOCD_NAMESPACE"
        "TDP_NAMESPACE"
        "TDP_PROJECT_NAMESPACE"
        "GIT_REPO_URL"
        "HELM_CHART_REPO_URL"
        "HELM_CHART_VERSION"
        "KUBERNETES_SERVER"
        "TECNISYS_HELM_REGISTRY_USER"
        "TECNISYS_HELM_REGISTRY_TOKEN"
        "TDP_APPLICATIONS"
    )
    
    local missing_vars=()
    for var in "${required_vars[@]}"; do
        if [ -z "${!var:-}" ]; then
            missing_vars+=("$var")
        fi
    done
    
    if [ ${#missing_vars[@]} -ne 0 ]; then
        print_error "Missing required variables: ${missing_vars[*]}"
        print_info "Please update your variables.env file with the missing variables."
        exit 1
    fi
    
    print_success "All required variables are set"
}

# Function to create backup of original files
create_backup() {
    print_info "Creating backup of original YAML files..."
    
    if [ -d "$BACKUP_DIR" ]; then
        local timestamp=$(date +"%Y%m%d_%H%M%S")
        print_warning "Backup directory exists, creating timestamped backup: backup_${timestamp}"
        mv "$BACKUP_DIR" "${SCRIPT_DIR}/backup_${timestamp}"
    fi
    
    mkdir -p "$BACKUP_DIR"
    
    # Backup common files
    if [ -d "$COMMON_DIR" ]; then
        while IFS= read -r -d '' file; do
            relative="${file#$SCRIPT_DIR/}"
            dest="$BACKUP_DIR/$relative"
            mkdir -p "$(dirname "$dest")"
            cp "$file" "$dest"
        done < <(find "$COMMON_DIR" -name "*.yaml" -print0)
    fi
    
    # Backup available files
    if [ -d "$AVAILABLE_DIR" ]; then
        while IFS= read -r -d '' file; do
            relative="${file#$SCRIPT_DIR/}"
            dest="$BACKUP_DIR/$relative"
            mkdir -p "$(dirname "$dest")"
            cp "$file" "$dest"
        done < <(find "$AVAILABLE_DIR" -name "*.yaml" -print0)
    fi
    
    print_success "Backup created in: $BACKUP_DIR"
}

# Log in to the Helm OCI registry (only the hostname, not the full path)
helm_registry_login() {
    [ "${HELM_LOGGED_IN:-false}" = "true" ] && return 0
    local registry_host
    registry_host=$(echo "${HELM_CHART_REPO_URL}" | cut -d'/' -f1)
    print_info "Logging into Helm OCI registry: ${registry_host}"
    if ! helm registry login "${registry_host}" \
            --username "${TECNISYS_HELM_REGISTRY_USER}" \
            --password-stdin <<< "${TECNISYS_HELM_REGISTRY_TOKEN}"; then
        print_error "Failed to authenticate to Helm registry"
        exit 1
    fi
    HELM_LOGGED_IN=true
}

# Install tdp-crds unless both the ArgoCD and the license CRDs are already there
install_crds() {
    if kubectl get crd applications.argoproj.io &>/dev/null \
            && kubectl get crd platformlicenses.licensing.tecnisys.com.br &>/dev/null; then
        print_warning "ArgoCD and license CRDs already installed — skipping tdp-crds (upgrade if needed: helm upgrade tdp-crds ...)"
        # Helm never upgrades CRDs. Without status.capacity in the schema the API
        # server drops the operator's worker-node count (no UNDER_LICENSED alert).
        local capacity_type
        capacity_type=$(kubectl get crd platformlicenses.licensing.tecnisys.com.br -o \
            jsonpath='{.spec.versions[?(@.name=="v1alpha1")].schema.openAPIV3Schema.properties.status.properties.capacity.type}' 2>/dev/null || true)
        if [ "$capacity_type" != "object" ]; then
            print_warning "The PlatformLicense CRD predates worker-node capacity (Helm never upgrades CRDs). Update it:"
            print_warning "  helm pull oci://${HELM_CHART_REPO_URL}/tdp-crds --version ${HELM_CHART_VERSION} --untar --untardir /tmp/tdp-crds"
            print_warning "  kubectl apply --server-side --force-conflicts -f /tmp/tdp-crds/tdp-crds/crds/tdp-crds-license/"
        fi
        return 0
    fi
    # Upgrade an existing tdp-crds release where it lives (an older one may lack the license CRDs)
    local crds_ns
    crds_ns=$(helm list -A --filter '^tdp-crds$' 2>/dev/null | awk 'NR==2 {print $2}')
    if [ -z "$crds_ns" ] && ! kubectl get namespace "${ARGOCD_NAMESPACE}" &>/dev/null; then
        print_info "Creating namespace: ${ARGOCD_NAMESPACE}"
        kubectl create namespace "${ARGOCD_NAMESPACE}"
    fi
    print_info "Installing tdp-crds v${HELM_CHART_VERSION}..."
    if ! helm upgrade --install tdp-crds \
            "oci://${HELM_CHART_REPO_URL}/tdp-crds" \
            --version "${HELM_CHART_VERSION}" \
            --namespace "${crds_ns:-$ARGOCD_NAMESPACE}" \
            --wait --timeout 120s; then
        print_error "Failed to install tdp-crds"
        exit 1
    fi
    print_success "tdp-crds installed"
}

# Install tdp-license-operator and the license. tdp-argo and every TDP
# component chart refuse to install without them (templates/tdp-license-check.yaml).
# Same steps as scripts/tdp-license-install.sh in the tdp-k8s repository, which
# does this for a stack installed with Helm instead of this kit.
install_license() {
    print_info "=== Installing the license (tdp-license-operator) ==="
    local ns="${TDP_LICENSE_NAMESPACE}"
    local keys_file lease_file
    keys_file=$(resolve_path "${TDP_LICENSE_PUBLIC_KEYS_FILE:-}")
    lease_file=$(resolve_path "${TDP_LICENSE_FILE:-}")
    if [ ! -f "$keys_file" ] || [ ! -f "$lease_file" ]; then
        print_error "The license files from Tecnisys are required: TDP_LICENSE_PUBLIC_KEYS_FILE (${keys_file:-unset}) and TDP_LICENSE_FILE (${lease_file:-unset})"
        exit 1
    fi
    local keys_json
    keys_json=$(tr -d '\n' < "$keys_file")
    if [[ ! "$keys_json" =~ ^[[:space:]]*\{.*\}[[:space:]]*$ ]]; then
        print_error "$keys_file is not a JSON object like {\"<key_id>\": \"<base64 key>\"}"
        exit 1
    fi

    if ! kubectl get namespace "$ns" &>/dev/null; then
        print_info "Creating namespace: $ns"
        kubectl create namespace "$ns"
    fi
    # The operator image comes from registry.tecnisys.com.br/tdp: the same pull
    # secret as the components (tdp-image-pull-secret.yaml), in the license namespace.
    if [ "$FORCE_VALUES" = "true" ] || ! kubectl -n "$ns" get secret tdp-registry &>/dev/null; then
        kubectl -n "$ns" create secret docker-registry tdp-registry \
            --docker-server=registry.tecnisys.com.br \
            --docker-username="${TECNISYS_HELM_REGISTRY_USER}" \
            --docker-password="${TECNISYS_HELM_REGISTRY_TOKEN}" \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        print_info "  ✓ secret $ns/tdp-registry"
    else
        print_warning "  Kept existing secret $ns/tdp-registry (use --force to replace it)"
    fi

    # JSON is valid YAML, so the trusted keys go into a values file as is. They
    # are passed on every run: an upgrade without them empties the trusted-keys Secret.
    local keys_values
    keys_values=$(mktemp)
    printf 'tdp-license-operator:\n  publicKeys: %s\n' "$keys_json" > "$keys_values"
    print_info "Installing tdp-license v${HELM_CHART_VERSION} into $ns..."
    if ! helm upgrade --install tdp-license \
            "oci://${HELM_CHART_REPO_URL}/tdp-license" \
            --version "${HELM_CHART_VERSION}" \
            --namespace "$ns" \
            -f "$keys_values" \
            --wait --timeout 300s; then
        rm -f "$keys_values"
        print_error "Failed to install tdp-license"
        exit 1
    fi
    rm -f "$keys_values"
    print_success "tdp-license installed"

    # Only a status written after this lease is applied counts below
    local verified_before
    verified_before=$(kubectl -n "$ns" get platformlicense tdp-platform -o jsonpath='{.status.lastVerifiedAt}' 2>/dev/null || true)

    # The lease: the lease.json envelope, or the Secret manifest tdp-license-cli writes
    if grep -q '^[[:space:]]*{' "$lease_file"; then
        kubectl -n "$ns" create secret generic tecnisys-license-lease --from-file=lease.json="$lease_file" \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    elif grep -q '^kind:[[:space:]]*Secret' "$lease_file" && grep -q 'name:[[:space:]]*tecnisys-license-lease' "$lease_file"; then
        kubectl -n "$ns" apply -f "$lease_file" >/dev/null
    else
        print_error "$lease_file is neither a lease.json envelope nor a tecnisys-license-lease Secret manifest"
        exit 1
    fi
    print_info "  ✓ secret $ns/tecnisys-license-lease"

    # Whole-platform licensing: one LicensePolicy + PlatformLicense pair with
    # product "*" governs every tecnisys.com/licensed=true workload in the
    # namespaces below.
    local governed="${TDP_LICENSE_POLICY_NAMESPACES:-$TDP_NAMESPACE}" ns_list="" item
    local -a governed_list
    IFS=',' read -r -a governed_list <<< "$governed"
    for item in "${governed_list[@]}"; do
        item=$(echo "$item" | xargs)
        [ -n "$item" ] && ns_list+="    - ${item}"$'\n'
    done
    kubectl apply -f - >/dev/null <<EOF
apiVersion: licensing.tecnisys.com.br/v1alpha1
kind: LicensePolicy
metadata:
  name: tdp-platform
  namespace: ${ns}
  labels:
    app.kubernetes.io/part-of: tdp-license-operator
spec:
  product: "*"
  namespaces:
${ns_list}  selector: {}
  expiration:
    deployments: ScaleToZero
    statefulSets: ScaleToZero
    cronJobs: Suspend
---
apiVersion: licensing.tecnisys.com.br/v1alpha1
kind: PlatformLicense
metadata:
  name: tdp-platform
  namespace: ${ns}
  labels:
    app.kubernetes.io/part-of: tdp-license-operator
spec:
  product: "*"
  enforcement: true
  allowedClockSkew: 5m
  policyRef: tdp-platform
  licenseSecretRef:
    name: tecnisys-license-lease
    key: lease.json
  publicKeysRef:
    name: tdp-license-operator-public-keys
    key: keys.json
EOF
    print_info "  ✓ LicensePolicy + PlatformLicense $ns/tdp-platform (governs: $governed)"

    # Wait for the operator to verify this lease: it re-reads the Secret within
    # seconds and re-verifies every 30s.
    print_info "Waiting for the license to be verified..."
    local deadline=$((SECONDS + 180)) status state="" verified signature_ok
    while [ "$SECONDS" -lt "$deadline" ]; do
        status=$(kubectl -n "$ns" get platformlicense tdp-platform \
            -o jsonpath='{.status.state}|{.status.lastVerifiedAt}|{.status.conditions[?(@.type=="Verified")].status}' 2>/dev/null || true)
        IFS='|' read -r state verified signature_ok <<< "$status"
        if [ -n "$verified" ] && [ "$verified" != "$verified_before" ] && [ "$signature_ok" = "True" ]; then
            break
        fi
        state=""
        sleep 3
    done
    kubectl -n "$ns" get platformlicense tdp-platform || true
    case "$state" in
        VALID|WARNING)
            print_success "License is $state"
            ;;
        *)
            print_error "License is ${state:-not verified}: $(kubectl -n "$ns" get platformlicense tdp-platform -o jsonpath='{.status.message} {.status.conditions[?(@.type=="Verified")].message}' 2>/dev/null)"
            print_info "ArgoCD and the TDP components cannot be installed until it is VALID. Check the license files and: kubectl -n $ns logs deploy/tdp-license-operator-operator"
            exit 1
            ;;
    esac
}

# Function to install ArgoCD (tdp-argo) via Helm OCI registry. tdp-crds and the
# license must be installed first: tdp-argo refuses to install without them.
install_argocd() {
    print_info "=== Installing ArgoCD ==="

    if ! kubectl get namespace "${ARGOCD_NAMESPACE}" &>/dev/null; then
        print_info "Creating namespace: ${ARGOCD_NAMESPACE}"
        kubectl create namespace "${ARGOCD_NAMESPACE}"
    fi

    # Exposed like the components: argo.${TDP_DOMAIN}
    # through TDP_EXPOSE, so no helm upgrade is needed afterwards
    local argo_host="argo.${TDP_DOMAIN}"
    local argo_args=(
        --set-string "tdp-argo.global.domain=${argo_host}"
        --set-string "tdp-argo.configs.cm.url=https://${argo_host}"
        --set "TDP-Settings.gateway.ingress.enabled=${TDP_INGRESS_ENABLED}"
        --set "TDP-Settings.gateway.gatewayApi.enabled=${TDP_GATEWAYAPI_ENABLED}"
    )
    if [ "$TDP_INGRESS_ENABLED" = "true" ]; then
        argo_args+=(
            --set "tdp-argo.server.ingress.enabled=true"
            --set-string "tdp-argo.server.ingress.hostname=${argo_host}"
        )
        # Empty TDP_INGRESS_CLASS keeps the chart default, as for the components
        if [ -n "$TDP_INGRESS_CLASS" ]; then
            argo_args+=(--set-string "tdp-argo.server.ingress.ingressClassName=${TDP_INGRESS_CLASS}")
        fi
    elif [ "$TDP_GATEWAYAPI_ENABLED" = "true" ]; then
        # The HTTPRoute lives in ARGOCD_NAMESPACE, so an empty TDP_GATEWAY_NAMESPACE
        # has to be spelled out as TDP_NAMESPACE (what it means for the components).
        # gatewayApi.gateway.enabled=false: use the shared Gateway, not one per
        # release; the chart also fails without it when Gateway API is on.
        argo_args+=(
            --set "gatewayApi.gateway.enabled=false"
            --set-string "gatewayApi.parentRefs[0].name=${TDP_GATEWAY_NAME}"
            --set-string "gatewayApi.parentRefs[0].namespace=${TDP_GATEWAY_NAMESPACE:-$TDP_NAMESPACE}"
            --set-string "gatewayApi.server.hostnames[0]=${argo_host}"
        )
    fi

    print_info "Installing tdp-argo v${HELM_CHART_VERSION}..."
    if ! helm upgrade --install tdp-argo \
            "oci://${HELM_CHART_REPO_URL}/tdp-argo" \
            --version "${HELM_CHART_VERSION}" \
            --namespace "${ARGOCD_NAMESPACE}" \
            --set skipCrdCheck=false \
            "${argo_args[@]}" \
            --wait --timeout 300s; then
        print_error "Failed to install tdp-argo"
        exit 1
    fi
    print_success "ArgoCD (tdp-argo) installed"

    # Wait for ArgoCD server and controller to be fully ready
    print_info "Waiting for ArgoCD components to be ready..."
    kubectl rollout status deployment/tdp-argocd-server \
        -n "${ARGOCD_NAMESPACE}" --timeout=180s
    kubectl rollout status statefulset/tdp-argocd-application-controller \
        -n "${ARGOCD_NAMESPACE}" --timeout=180s

    print_success "ArgoCD is running in namespace: ${ARGOCD_NAMESPACE}"
    case "$TDP_INGRESS_ENABLED/$TDP_GATEWAYAPI_ENABLED" in
        true/*) print_info "ArgoCD UI: ${argo_host} (Ingress)" ;;
        */true) print_info "ArgoCD UI: ${argo_host} (HTTPRoute on Gateway ${TDP_GATEWAY_NAMESPACE:-$TDP_NAMESPACE}/${TDP_GATEWAY_NAME}; its listener must allow routes from ${ARGOCD_NAMESPACE})" ;;
        *)      print_info "ArgoCD UI not exposed (TDP_EXPOSE=none): kubectl -n ${ARGOCD_NAMESPACE} port-forward svc/tdp-argocd-server 8080:80" ;;
    esac
    print_info "Admin password: kubectl -n ${ARGOCD_NAMESPACE} get secret tdp-argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

# Function to restore from backup
restore_backup() {
    if [ ! -d "$BACKUP_DIR" ]; then
        print_error "No backup directory found: $BACKUP_DIR"
        exit 1
    fi
    
    print_info "Restoring files from backup..."
    
    # Restore common files
    if [ -d "${BACKUP_DIR}/common" ]; then
        cp -r "${BACKUP_DIR}/common/"* "$COMMON_DIR/"
    fi
    
    # Restore available files
    if [ -d "${BACKUP_DIR}/available" ]; then
        cp -r "${BACKUP_DIR}/available/"* "$AVAILABLE_DIR/"
    fi
    
    print_success "Files restored from backup"
}

# Function to render a single template file to an output path (never modifies source)
render_yaml_file() {
    local src="$1"
    local dst="$2"
    
    mkdir -p "$(dirname "$dst")"

    # Variables are already exported by validate_variables_file (re-sourcing the
    # file here would undo -d/--domain).
    # Build substitution list from only the variables defined in the variables file
    # (plus OPTIONAL_VARS). This prevents envsubst from replacing ArgoCD-specific
    # references like $values, or ${HOME} inside chart values.
    local var_list
    var_list=$( { grep -v '^#' "$VARIABLES_FILE" | grep -v '^[[:space:]]*$' | cut -d= -f1; printf '%s\n' "${OPTIONAL_VARS[@]}" "${PASSWORD_VARS[@]}" "${SECRET_KEY_VARS[@]}"; } \
        | sort -u | sed 's/^/\${/' | sed 's/$/}/' | tr '\n' ' ')

    # Use envsubst to replace only the declared variables
    if envsubst "$var_list" < "$src" > "$dst"; then
        return 0
    else
        print_error "Failed to render: $src"
        rm -f "$dst"
        return 1
    fi
}

# Function to fill in the component passwords before rendering components.
# Each one falls back to TDP_DEFAULT_PASSWORD and is checked against the
# characters every consumer accepts unescaped (YAML, XML, shell, SQL and the
# Superset database URI).
resolve_passwords() {
    local var value defaults=()
    local allowed='^[A-Za-z0-9!._~-]{8,}$'
    for var in "${PASSWORD_VARS[@]}"; do
        value="${!var:-${TDP_DEFAULT_PASSWORD:-}}"
        if [ -z "$value" ]; then
            print_error "$var is empty and TDP_DEFAULT_PASSWORD is not set (see variables.env)"
            exit 1
        fi
        if ! [[ "$value" =~ $allowed ]]; then
            print_error "$var: use at least 8 characters from A-Z a-z 0-9 ! . _ ~ -"
            exit 1
        fi
        [ "$value" = "$SHIPPED_DEFAULT_PASSWORD" ] && defaults+=("$var")
        printf -v "$var" '%s' "$value"
        export "${var?}"
    done
    if [ ${#defaults[@]} -gt 0 ]; then
        print_warning "${#defaults[@]} component password(s) still use the shipped default ${SHIPPED_DEFAULT_PASSWORD} — set TDP_DEFAULT_PASSWORD (or the TDP_*_PASSWORD entries) before real use"
    fi
}

# Function to fill in a component's secret key (Superset's SECRET_KEY signs the
# session cookies and encrypts the database passwords Superset stores; the Ozone
# KDC master password creates the KDC database), so it must stay the same across
# renders: the variable wins, then the key already rendered in current/, and only
# then a new random one.
#   $1 variable  $2 component  $3 YAML key holding it  $4 what a new key does
#   to an existing install (empty: no warning)  $5 values file holding it
#   (default values-gitops.yaml)
resolve_secret_key() {
    local var="$1" component="$2" key="$3" impact="$4" file="${5:-values-gitops.yaml}"
    local rendered="${CURRENT_DIR}/${component}/${file}"
    local allowed='^[A-Za-z0-9+/=._~-]{32,}$'
    local value="${!var:-}"
    if [ -z "$value" ] && [ -f "$rendered" ]; then
        value=$(sed -nE "s/^ *${key}: *'([^']*)'.*/\1/p" "$rendered" | head -1)
    fi
    if [ -z "$value" ]; then
        value=$(head -c 42 /dev/urandom | base64 | tr -d '\n')
        print_info "Generated a new ${var} (copy it from current/${component}/${file} to your variables file to keep it)"
        if [ -n "$impact" ] && [ -f "${CURRENT_DIR}/${component}/values.yaml" ]; then
            print_warning "current/${component} already exists: a new secret key ${impact} — set ${var} to the key in use instead"
        fi
    fi
    if ! [[ "$value" =~ $allowed ]]; then
        print_error "${var}: use at least 32 characters from A-Z a-z 0-9 + / = . _ ~ -"
        exit 1
    fi
    printf -v "$var" '%s' "$value"
    export "${var?}"
}

# Function to keep the rendered components consistent with Ozone security.
# Once current/ holds a values-ozone-security.yaml, a component rendered with
# TDP_OZONE_SECURITY=false would miss its own and keep the placeholder S3 keys
# (turning security off is not supported). With it on, tdp-ozone must have its
# overlay, or nothing fills the Secret the other overlays wait for.
check_ozone_security() {
    local secured
    secured=$(find "$CURRENT_DIR" -mindepth 2 -maxdepth 2 -name values-ozone-security.yaml 2>/dev/null | sort | head -1)
    if [ "$TDP_OZONE_SECURITY" != "true" ]; then
        if [ -n "$secured" ]; then
            print_error "Ozone security is on in current/ (${secured#"${CURRENT_DIR}/"}) but TDP_OZONE_SECURITY is not true in ${VARIABLES_FILE}: set it to true (turning Ozone security off is not supported)"
            exit 1
        fi
        return 0
    fi
    if [ ! -f "${CURRENT_DIR}/tdp-ozone/values-ozone-security.yaml" ] \
        && [[ " ${selected_components[*]-} " != *" tdp-ozone "* ]]; then
        print_warning "TDP_OZONE_SECURITY=true but current/tdp-ozone has no values-ozone-security.yaml: render tdp-ozone too (enable-ozone-security.sh does), or the other components wait for an S3 Secret nothing fills"
    fi
}

# Function to render available/ templates into current/ (App of Apps flow)
render_to_current() {
    process_yaml_files "$@"
}

# Function to process all YAML files
process_yaml_files() {
    local selected_components=()
    [ $# -gt 0 ] && selected_components=("$@")
    local yaml_files=()
    local processed_files=0
    local failed_files=0
    
    print_info "Rendering templates to current/ ..."
    mkdir -p "$CURRENT_DIR"
    
    # Always process common files
    if [ -d "$COMMON_DIR" ]; then
        while IFS= read -r -d '' src; do
            local rel="${src#"$COMMON_DIR/"}"
            local dst="${CURRENT_DIR}/common/${rel}"
            if render_yaml_file "$src" "$dst"; then
                processed_files=$((processed_files + 1))
            else
                failed_files=$((failed_files + 1))
            fi
        done < <(find "$COMMON_DIR" -name "*.yaml" -print0)
    fi
    
    # Process available files only for the selected components (none → common only).
    # Other components already in current/ are left alone: removing them would make
    # the App of Apps prune their Applications.
    if [ ${#selected_components[@]} -eq 0 ]; then
        print_info "No components selected — rendered current/common/ only (name components or use --all-components)"
    fi
    for component in ${selected_components[@]+"${selected_components[@]}"}; do
        while IFS= read -r -d '' file; do
            yaml_files+=("$file")
        done < <(find "${AVAILABLE_DIR}/${component}" -name "*.yaml" -print0 2>/dev/null)
    done

    local skipped_files=0
    for file in ${yaml_files[@]+"${yaml_files[@]}"}; do
        local rel="${file#"$AVAILABLE_DIR/"}"
        local dst="${CURRENT_DIR}/${rel}"
        # The Ozone security overlays only exist with TDP_OZONE_SECURITY=true
        if [ "$(basename "$file")" = "values-ozone-security.yaml" ] && [ "${TDP_OZONE_SECURITY:-false}" != "true" ]; then
            continue
        fi
        # values*.yaml in current/ may hold hand edits: keep them unless --force.
        # The Application manifest is always refreshed.
        if [[ "$(basename "$file")" == values*.yaml ]] && [ -f "$dst" ] && [ "$FORCE_VALUES" != "true" ]; then
            print_warning "  Kept existing current/${rel} (use --force to overwrite)"
            skipped_files=$((skipped_files + 1))
            continue
        fi
        if render_yaml_file "$file" "$dst"; then
            processed_files=$((processed_files + 1))
        else
            failed_files=$((failed_files + 1))
        fi
    done

    # The kit only uses registry.tecnisys.com.br: flag dev-registry refs (comments aside)
    local dev_refs
    dev_refs=$(grep -rnE 'registry\.engtecnisys\.com\.br|/tdp-dev/' "$CURRENT_DIR" --include='*.yaml' 2>/dev/null \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
    if [ -n "$dev_refs" ]; then
        print_warning "current/ references the dev registry; the kit must only use registry.tecnisys.com.br:"
        echo "$dev_refs" | head -10
    fi

    print_success "Rendered $processed_files files to current/"
    [ $skipped_files -gt 0 ] && print_info "Kept $skipped_files existing values files"
    [ $failed_files -gt 0 ] && print_warning "Failed to render $failed_files files"
    return $failed_files
}

# Function to list every component in the available/ catalog
list_components() {
    find "$AVAILABLE_DIR" -mindepth 1 -maxdepth 1 -type d -name "tdp-*" -exec basename {} \; | sort
}

# Function to apply manifests to Kubernetes
# Reads from current/ (rendered) if available, otherwise renders on the fly from available/
apply_manifests() {
    local apply_common="${1:-true}"
    local apply_available="${2:-false}"
    local selected_components=()
    [ $# -ge 3 ] && selected_components=("${@:3}")
    
    print_info "Applying manifests to Kubernetes..."
    
    if ! kubectl cluster-info &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster"
        print_info "Please check your kubectl configuration"
        exit 1
    fi
    
    # Apply common resources (rendered to current/common/ or from common/ directly)
    if [ "$apply_common" = "true" ]; then
        local common_src="${CURRENT_DIR}/common"
        [ ! -d "$common_src" ] && common_src="$COMMON_DIR"
        print_info "Applying common resources from: $common_src"
        # The image pull secret lives in the components' namespace
        if ! kubectl get namespace "${TDP_NAMESPACE}" &>/dev/null; then
            print_info "Creating namespace: ${TDP_NAMESPACE}"
            kubectl create namespace "${TDP_NAMESPACE}"
        fi
        # The App of Apps goes last: applied before the AppProject and the repo
        # Secrets, ArgoCD reports "project ... does not exist" / auth errors on it.
        local app_of_apps="$common_src/argo-gitops-app-of-apps.yaml"
        local common_files=()
        for file in "$common_src"/*.yaml; do
            [ -f "$file" ] && [ "$file" != "$app_of_apps" ] && common_files+=("$file")
        done
        [ -f "$app_of_apps" ] && common_files+=("$app_of_apps")
        for file in ${common_files[@]+"${common_files[@]}"}; do
            # Don't replace a tdp-registry Secret someone created by hand (it may
            # cover more registries) unless --force.
            if [ "$(basename "$file")" = "tdp-image-pull-secret.yaml" ] && [ "$FORCE_VALUES" != "true" ] \
                && kubectl -n "${TDP_NAMESPACE}" get secret tdp-registry &>/dev/null; then
                print_warning "  Kept existing secret ${TDP_NAMESPACE}/tdp-registry (use --force to replace it)"
                continue
            fi
            kubectl apply -f "$file" && print_info "  ✓ $(basename "$file")"
        done
    fi
    
    # Apply Application manifests (from current/ if rendered, else render on-the-fly)
    if [ "$apply_available" = "true" ]; then
        if [ ${#selected_components[@]} -eq 0 ]; then
            print_warning "No components selected — nothing to apply (name components or use --all-components)"
        else
            print_info "Applying selected components: ${selected_components[*]}"
            for component in "${selected_components[@]}"; do
                local rendered="${CURRENT_DIR}/${component}/${component}.yaml"
                local template="${AVAILABLE_DIR}/${component}/${component}.yaml"
                
                if [ -f "$rendered" ]; then
                    print_info "  Applying (rendered): $rendered"
                    kubectl apply -f "$rendered"
                elif [ -f "$template" ]; then
                    print_info "  Applying (on-the-fly): $template"
                    local tmp
                    tmp=$(mktemp)
                    render_yaml_file "$template" "$tmp" && kubectl apply -f "$tmp"
                    rm -f "$tmp"
                else
                    print_warning "  Component not found: $component"
                fi
            done
        fi
    fi
    
    print_success "Manifests applied successfully"
}

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] [COMPONENTS... | --all-components]

Renders common/ (and the selected components from available/) into current/,
then applies them with kubectl unless -p is given. Without arguments, prints
this help. Without components, only current/common/ is rendered.

Options:
  -h, --help              Show this help message
  --install               Install tdp-crds, the license (tdp-license-operator + the
                          TDP_LICENSE_* files) and ArgoCD (tdp-argo), then apply common
                          resources; the UI is exposed at argo.DOMAIN per -e/TDP_EXPOSE
  --license               Install or renew only the license (tdp-crds if missing,
                          tdp-license-operator, lease, PlatformLicense) and stop
  -p, --render-only       Render templates to current/ only (no apply)
  -c, --common-only       Apply common resources only (AppProject + Secrets + App of Apps)
  -a, --available-only    Apply the selected components' Application manifests only
  --all-components        Select every component in available/
  -d, --domain DOMAIN     Domain for Ingress/Gateway API hostnames (<component>.DOMAIN);
                          overrides TDP_DOMAIN from the variables file
  -e, --expose MODE       How components are exposed: ingress, gatewayapi or none;
                          overrides TDP_EXPOSE (gatewayapi needs TDP_GATEWAY_NAME)
  -v, --variables FILE    Use custom variables file (default: variables.env)
  -f, --force             Overwrite existing current/<component>/values*.yaml
                          (kept by default, as they may hold local edits) and
                          replace an existing tdp-registry pull secret in TDP_NAMESPACE
  -r, --restore           Legacy no-op
  -b, --no-backup         Legacy no-op

Rendering only adds or refreshes files: components already in current/ but not
selected are left alone, so the App of Apps does not prune them.

Ozone security (Kerberos + real S3 authentication) is off by default. With
TDP_OZONE_SECURITY=true each component's values-ozone-security.yaml is rendered
too; ./enable-ozone-security.sh turns it on and renders what it needs.

Deployment Modes:

  FIRST TIME SETUP — installs the license and ArgoCD, and bootstraps GitOps.
  ArgoCD and every TDP component refuse to install without a VALID license, so
  put the two files from Tecnisys where TDP_LICENSE_PUBLIC_KEYS_FILE and
  TDP_LICENSE_FILE point first:
    $0 --install -v variables.env.local   # License + ArgoCD + common resources
    git add current/ && git push          # Publish rendered manifests for App of Apps

  GITOPS (after bootstrap) — App of Apps reads current/ from git automatically:
    $0 -p -v variables.env.local tdp-postgresql tdp-trino   # Render components, then git push
    $0 -p -v variables.env.local --all-components            # Render every component
    $0 -c -v variables.env.local                             # Re-apply common resources only

  DIRECT — apply Applications directly via kubectl (no git push needed):
    $0 -a -v variables.env.local tdp-postgresql              # Render + apply one component
    $0 -a -v variables.env.local --all-components            # Render + apply every component

Examples:
  $0 --install -v variables.env.local                        # Full first-time setup
  $0 --license -v variables.env.local                        # Renew the license (new lease file)
  $0 -p -v variables.env.local -d example.com --all-components  # Hosts like airflow.example.com
  $0 -p -v variables.env.local -e ingress --force tdp-trino      # Expose Trino through an Ingress
  $0 -p -v variables.env.local && git add current/ && git push  # Refresh current/common only

Components:
EOF
    
    if [ -d "$AVAILABLE_DIR" ]; then
        list_components
    fi
}

# Main script execution
main() {
    local render_only=false
    local apply_common=true
    local apply_available=false
    local install_mode=false
    local license_mode=false
    local all_components=false
    local common_only=false
    local selected_components=()

    if [ $# -eq 0 ]; then
        show_usage
        exit 0
    fi
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -r|--restore)
                print_warning "--restore is a legacy no-op. Templates in available/ are never modified."
                exit 0
                ;;
            --install)
                install_mode=true
                shift
                ;;
            --license)
                license_mode=true
                shift
                ;;
            -p|--render-only|--process-only)
                render_only=true
                shift
                ;;
            -c|--common-only)
                common_only=true
                apply_common=true
                apply_available=false
                shift
                ;;
            -a|--available-only)
                apply_common=false
                apply_available=true
                shift
                ;;
            --all-components)
                all_components=true
                shift
                ;;
            -d|--domain)
                if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
                    print_error "$1 needs a domain (e.g. $1 example.com)"
                    exit 1
                fi
                DOMAIN_OVERRIDE="$2"
                shift 2
                ;;
            -e|--expose)
                if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
                    print_error "$1 needs a mode: ingress, gatewayapi or none"
                    exit 1
                fi
                EXPOSE_OVERRIDE="$2"
                shift 2
                ;;
            -f|--force)
                FORCE_VALUES=true
                shift
                ;;
            -b|--no-backup)
                shift
                ;;
            -v|--variables)
                if [ -z "${2:-}" ]; then
                    print_error "$1 needs a file"
                    exit 1
                fi
                VARIABLES_FILE="$2"
                [[ "$VARIABLES_FILE" != /* ]] && VARIABLES_FILE="$(pwd)/$VARIABLES_FILE"
                shift 2
                ;;
            -*)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                selected_components+=("$1")
                shift
                ;;
        esac
    done

    if [ "$all_components" = "true" ]; then
        if [ ${#selected_components[@]} -gt 0 ]; then
            print_error "Use either component names or --all-components, not both"
            exit 1
        fi
        while IFS= read -r component; do
            selected_components+=("$component")
        done < <(list_components)
    fi

    local component
    for component in ${selected_components[@]+"${selected_components[@]}"}; do
        if [ ! -d "${AVAILABLE_DIR}/${component}" ]; then
            print_error "Unknown component: $component (see $0 --help for the list)"
            exit 1
        fi
    done
    
    print_info "TDP GitOps Deployment Script"
    print_info "============================"
    
    local need_helm=false
    { [ "$install_mode" = "true" ] || [ "$license_mode" = "true" ]; } && need_helm=true
    check_dependencies "$render_only" "$need_helm"
    validate_variables_file

    # --license: install or renew only the operator and the license, then stop
    if [ "$license_mode" = "true" ] && [ "$install_mode" != "true" ]; then
        helm_registry_login
        install_crds
        install_license
        print_success "License installed. ArgoCD and the TDP components can now be installed."
        exit 0
    fi

    # --install: CRDs, then the license (tdp-argo and every component refuse
    # to install without it), then ArgoCD, before applying common resources
    if [ "$install_mode" = "true" ]; then
        helm_registry_login
        install_crds
        install_license
        install_argocd
        # After install, fall through to render + apply common
    fi
    
    # Component templates carry passwords; common/ does not
    if [ ${#selected_components[@]} -gt 0 ]; then
        resolve_passwords
    fi
    if [[ " ${selected_components[*]-} " == *" tdp-superset "* ]]; then
        resolve_secret_key TDP_SUPERSET_SECRET_KEY tdp-superset SUPERSET_SECRET_KEY \
            "makes the connection passwords an existing Superset stored unreadable"
    fi
    if [ ${#selected_components[@]} -gt 0 ]; then
        check_ozone_security
    fi
    if [ "$TDP_OZONE_SECURITY" = "true" ] && [[ " ${selected_components[*]-} " == *" tdp-ozone "* ]]; then
        # Only used when the KDC database is first created
        resolve_secret_key TDP_OZONE_KDC_MASTER_PASSWORD tdp-ozone masterPassword "" values-ozone-security.yaml
    fi

    # Render common/ + selected components → current/ (templates stay untouched)
    render_to_current ${selected_components[@]+"${selected_components[@]}"}

    # Apply manifests if not process-only. Plain runs (no -c/-a) apply common
    # resources plus any selected components.
    if [ "$render_only" = "false" ]; then
        if [ "$common_only" = "false" ] && [ ${#selected_components[@]} -gt 0 ]; then
            apply_available=true
        fi
        apply_manifests "$apply_common" "$apply_available" ${selected_components[@]+"${selected_components[@]}"}
    else
        print_info "Processing completed. Run without -p to apply manifests."
    fi
    
    print_success "Deployment completed successfully!"

    if [ ${#selected_components[@]} -gt 0 ]; then
        print_warning "current/<component>/values*.yaml now hold the component passwords: keep the GitOps repository private."
    fi

    cat << EOF

Next steps:
1. Check application status:
   kubectl get applications -n ${ARGOCD_NAMESPACE:-argocd}

2. Monitor deployment:
   kubectl get pods -n ${TDP_NAMESPACE:-tdp-testes}

3. Check ArgoCD UI for detailed status

EOF
}

# Run main function with all arguments
main "$@"