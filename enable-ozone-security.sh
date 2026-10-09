#!/bin/bash

# Turns on Ozone security in the GitOps kit: Kerberos (tdp-ozone's internal KDC)
# and real S3 authentication on Ozone's S3 Gateway, plus the matching
# credentials in every component that uses Ozone S3.
#
# It sets TDP_OZONE_SECURITY=true in the variables file and renders, with
# deploy.sh -p, tdp-ozone and the components already in current/ that read
# Ozone's S3 key (tdp-trino, tdp-spark, tdp-hive-metastore, tdp-clickhouse).
# Each gets its values-ozone-security.yaml; everything else in
# current/ is kept. Nothing is applied: commit and push current/ afterwards.
# Components rendered later get their overlay from deploy.sh.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_DIR="${SCRIPT_DIR}/current"
# Components with a values-ozone-security.yaml besides tdp-ozone
S3_CLIENTS=(tdp-trino tdp-spark tdp-hive-metastore tdp-clickhouse)

VARIABLES_FILE=""
ASSUME_YES=false
CHECK_CHART=true

print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

show_usage() {
    cat << EOF
Usage: $0 -v VARIABLES_FILE [-y] [--skip-chart-check]

Turns on Ozone security (Kerberos + real S3 authentication) in the GitOps kit:
sets TDP_OZONE_SECURITY=true in VARIABLES_FILE and renders tdp-ozone and the
Ozone S3 clients already in current/ (${S3_CLIENTS[*]})
with deploy.sh -p. Commit and push current/ afterwards.

Options:
  -v, --variables FILE    Your variables file (e.g. variables.env.local); it is edited
  -y, --yes               Do not ask for confirmation
  --skip-chart-check      Do not check that the tdp-ozone chart in HELM_CHART_VERSION
                          orders the keytab export for ArgoCD (needs helm and registry
                          access)
  -h, --help              Show this help message

Turning Ozone security on cannot be undone from the kit. It works on a new
tdp-ozone and on one already running without security, which keeps its data:
the daemons restart with Kerberos and the OM gets its SCM-signed certificate on
its first secure start. See "Ozone security" in README.md.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -v|--variables)
            [ $# -ge 2 ] || { print_error "$1 needs a file"; exit 1; }
            VARIABLES_FILE="$2"
            shift 2
            ;;
        -y|--yes) ASSUME_YES=true; shift ;;
        --skip-chart-check) CHECK_CHART=false; shift ;;
        -h|--help) show_usage; exit 0 ;;
        *) print_error "Unknown option: $1"; show_usage; exit 1 ;;
    esac
done

if [ -z "$VARIABLES_FILE" ]; then
    print_error "Name your variables file with -v (e.g. -v variables.env.local)"
    exit 1
fi
if [ ! -f "$VARIABLES_FILE" ]; then
    print_error "Variables file not found: $VARIABLES_FILE"
    exit 1
fi
if [ "$(cd "$(dirname "$VARIABLES_FILE")" && pwd)/$(basename "$VARIABLES_FILE")" = "${SCRIPT_DIR}/variables.env" ]; then
    print_error "variables.env is the kit's template: copy it to variables.env.local and use that"
    exit 1
fi

# shellcheck disable=SC1090
set -a; source "$VARIABLES_FILE"; set +a

# The keytab export must run as an ArgoCD Sync hook (wave -1): as PostSync it
# waits for the Ozone daemons, which wait for the keytabs, and the first sync
# with security on never completes.
check_chart() {
    if ! command -v helm >/dev/null 2>&1; then
        print_warning "helm not found: skipped the tdp-ozone chart check"
        return 0
    fi
    local tmp registry_host job
    tmp=$(mktemp -d)
    registry_host=$(echo "${HELM_CHART_REPO_URL}" | cut -d'/' -f1)
    # An existing helm login first; the kit's registry account only if that fails
    if ! helm pull "oci://${HELM_CHART_REPO_URL}/tdp-ozone" --version "${HELM_CHART_VERSION}" \
            --untar -d "$tmp" >/dev/null 2>&1; then
        if ! helm registry login "${registry_host}" --username "${TECNISYS_HELM_REGISTRY_USER}" \
                --password-stdin <<< "${TECNISYS_HELM_REGISTRY_TOKEN}" >/dev/null 2>&1 \
            || ! helm pull "oci://${HELM_CHART_REPO_URL}/tdp-ozone" --version "${HELM_CHART_VERSION}" \
                --untar -d "$tmp" >/dev/null 2>&1; then
            rm -rf "$tmp"
            print_warning "Could not pull tdp-ozone ${HELM_CHART_VERSION} from ${HELM_CHART_REPO_URL}: skipped the chart check"
            return 0
        fi
    fi
    job="$tmp/tdp-ozone/templates/kdc-keytab-export-job.yaml"
    if [ -f "$job" ] && grep -q '"argocd.argoproj.io/hook": "Sync"' "$job"; then
        print_success "tdp-ozone ${HELM_CHART_VERSION} orders the keytab export for ArgoCD"
        rm -rf "$tmp"
        return 0
    fi
    rm -rf "$tmp"
    print_error "tdp-ozone ${HELM_CHART_VERSION} exports the keytabs in PostSync: under ArgoCD the first sync with security on never completes. Use a chart version with the fix (HELM_CHART_VERSION), or --skip-chart-check if you know it has it."
    exit 1
}

already_on=false
if grep -qE '^TDP_OZONE_SECURITY=["'\'']?true' "$VARIABLES_FILE" \
    && [ -f "${CURRENT_DIR}/tdp-ozone/values-ozone-security.yaml" ]; then
    already_on=true
    print_info "Ozone security is already on: rendering any missing values-ozone-security.yaml"
fi

components=(tdp-ozone)
for c in "${S3_CLIENTS[@]}"; do
    [ -d "${CURRENT_DIR}/${c}" ] && components+=("$c")
done

if [ "$already_on" = "false" ]; then
    [ "$CHECK_CHART" = "true" ] && check_chart
    if [ -f "${CURRENT_DIR}/tdp-ozone/values.yaml" ]; then
        print_info "current/tdp-ozone already exists. If tdp-ozone is already deployed, its daemons restart one by one with Kerberos on the next sync and keep their data; the OM gets its SCM-signed certificate as it starts."
    fi
    cat << EOF

This turns Ozone security on for ${components[*]}:
  - tdp-ozone gets a KDC, Kerberos between its daemons and real S3 authentication.
    One OM-issued key for the Ozone admin "tdp-s3-admin" goes into the Secret
    ozone-s3-credentials, and every Ozone S3 client uses it.
  - The OM, SCM, Recon and S3 Gateway web UIs stay unauthenticated.
  - It cannot be turned off again from the kit.

EOF
    if [ "$ASSUME_YES" != "true" ]; then
        read -r -p "Continue? [y/N] " answer
        case "$answer" in
            y|Y|yes|YES) ;;
            *) print_info "Nothing changed"; exit 0 ;;
        esac
    fi

    if grep -qE '^TDP_OZONE_SECURITY=' "$VARIABLES_FILE"; then
        # Not sed -i: its syntax differs between GNU and BSD/macOS sed
        tmp=$(mktemp)
        sed -E 's/^TDP_OZONE_SECURITY=.*/TDP_OZONE_SECURITY=true/' "$VARIABLES_FILE" > "$tmp"
        cat "$tmp" > "$VARIABLES_FILE"
        rm -f "$tmp"
    else
        printf '\n# Ozone security (enable-ozone-security.sh)\nTDP_OZONE_SECURITY=true\n' >> "$VARIABLES_FILE"
    fi
    print_success "TDP_OZONE_SECURITY=true in ${VARIABLES_FILE}"
fi

"${SCRIPT_DIR}/deploy.sh" -p -v "$VARIABLES_FILE" "${components[@]}"

namespace="${TDP_NAMESPACE:-<TDP_NAMESPACE>}"
echo
print_success "Ozone security rendered for: ${components[*]}"
cat << EOF

Next steps:
1. Publish the rendered files (the KDC master password and the components'
   passwords are in current/: keep the repository private):
     git add current/ && git commit -m "feat: enable Ozone security" && git push
2. tdp-ozone syncs in order: KDC, keytab export, the Ozone daemons, then a
   PostSync Job fills the Secret ozone-s3-credentials. Wait until it has a key:
     kubectl -n ${namespace} get secret ozone-s3-credentials -o jsonpath='{.data.aws_access_key_id}'
3. Pods of the S3 clients that start before that wait in
   CreateContainerConfigError and start on their own once it is filled. Pods
   that were already running keep the old keys: restart the Deployments and
   StatefulSets of tdp-trino, tdp-spark, tdp-hive-metastore and tdp-clickhouse
   (ArgoCD UI "Restart", or kubectl rollout restart).
4. The buckets "warehouse" and "clickhouse-data" must exist in Ozone's /s3v
   volume. Create any missing one with the key from ozone-s3-credentials
   (README: "Ozone security").
EOF
