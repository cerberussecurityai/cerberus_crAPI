#!/bin/bash

# Helm deployment script for crAPI.
# Deploys the chart as base values.yaml + a values/<env>.yaml overlay, via
# `helm upgrade --install`, behind an optional env->cluster context guard.
#
# Usage: ./deploy-helm.sh [environment] [action] [options]
# Examples:
#   ./deploy-helm.sh dev install
#   ./deploy-helm.sh dev upgrade --dry-run
#   ./deploy-helm.sh dev diff
#   ./deploy-helm.sh dev rollback 3
#   ./deploy-helm.sh dev uninstall
#
# Optional context guard: export the kubectl context you expect each env to
# deploy to and the script refuses to run against the wrong cluster, e.g.
#   export CRAPI_DEV_CONTEXT=<your-dev-kubectl-context>
#   export CRAPI_PROD_CONTEXT=<your-prod-kubectl-context>
# Unset = guard skipped for that env. Override entirely with CRAPI_SKIP_CONTEXT_CHECK=1.

set -e

# Run from this script's directory so the relative chart/values paths resolve
# no matter where it's invoked from.
cd "$(dirname "$0")"

# Configuration
ENVIRONMENT=${1:-dev}
ACTION=${2:-upgrade}
RELEASE_NAME="crapi"
NAMESPACE="crapi"
CHART_PATH="."
VALUES_DIR="./values"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v helm &> /dev/null; then
        log_error "Helm is not installed"
        exit 1
    fi

    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed"
        exit 1
    fi

    # Check Helm version (should be v3)
    HELM_VERSION=$(helm version --short | cut -d: -f2 | cut -dv -f2 | cut -d. -f1)
    if [ "$HELM_VERSION" -lt "3" ]; then
        log_error "Helm v3 or higher is required"
        exit 1
    fi

    # Check kubectl connection
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Please configure kubectl."
        exit 1
    fi

    log_info "Prerequisites check passed"
}

# Validate environment
validate_environment() {
    if [ ! -f "$VALUES_DIR/$ENVIRONMENT.yaml" ]; then
        log_error "Environment file not found: $VALUES_DIR/$ENVIRONMENT.yaml"
        log_info "Available environments:"
        ls -1 $VALUES_DIR/*.yaml 2>/dev/null | xargs -n1 basename | sed 's/.yaml//'
        exit 1
    fi
}

# Guard: the kubectl context must match the env being deployed. The expected
# context per env is supplied via environment variables (see header) rather than
# hardcoded, so no cluster-specific names live in this repo. An unset variable
# means "no expectation configured" and the check is skipped for that env.
# Override entirely with CRAPI_SKIP_CONTEXT_CHECK=1 only in conscious flows.
expected_context_for() {
    case "$1" in
        dev)        echo "${CRAPI_DEV_CONTEXT:-}" ;;
        production) echo "${CRAPI_PROD_CONTEXT:-}" ;;
        *)          echo "" ;;
    esac
}

validate_context() {
    if [ "${CRAPI_SKIP_CONTEXT_CHECK:-0}" = "1" ]; then
        log_warn "CRAPI_SKIP_CONTEXT_CHECK=1 — skipping kubectl context guard"
        return
    fi

    local expected current
    expected=$(expected_context_for "$ENVIRONMENT")
    if [ -z "$expected" ]; then
        log_warn "No expected context set for env '$ENVIRONMENT' (export CRAPI_DEV_CONTEXT / CRAPI_PROD_CONTEXT to enable the guard) — skipping check"
        return
    fi

    current=$(kubectl config current-context 2>/dev/null || true)
    if [ "$current" != "$expected" ]; then
        log_error "kubectl context does NOT match environment '$ENVIRONMENT'"
        log_error "  expected: $expected"
        log_error "  current:  ${current:-<none>}"
        log_error ""
        log_error "Fix with:  kubectl config use-context $expected"
        log_error "Override:  CRAPI_SKIP_CONTEXT_CHECK=1 $0 $ENVIRONMENT $ACTION ..."
        exit 1
    fi
    log_info "Context OK for $ENVIRONMENT: $current"
}

# Install Helm chart
helm_install() {
    log_info "Installing crAPI Helm chart for $ENVIRONMENT environment..."

    # Helm creates the namespace with --create-namespace; no manual creation
    # (manual creation causes ownership conflicts on later upgrades).
    helm install $RELEASE_NAME $CHART_PATH \
        --namespace $NAMESPACE \
        --values $CHART_PATH/values.yaml \
        --values $VALUES_DIR/$ENVIRONMENT.yaml \
        --create-namespace \
        --wait \
        --timeout 15m \
        "${@:3}"

    log_info "Installation completed successfully!"
}

# Upgrade Helm release
helm_upgrade() {
    log_info "Upgrading crAPI Helm release for $ENVIRONMENT environment..."

    helm upgrade $RELEASE_NAME $CHART_PATH \
        --namespace $NAMESPACE \
        --values $CHART_PATH/values.yaml \
        --values $VALUES_DIR/$ENVIRONMENT.yaml \
        --install \
        --create-namespace \
        --timeout 15m \
        "${@:3}"

    log_info "Upgrade completed successfully!"
}

# Uninstall Helm release
helm_uninstall() {
    log_warn "Uninstalling crAPI Helm release..."
    log_warn "Note: 'helm uninstall' leaves StatefulSet PVCs (mongo/postgres/chroma)"
    log_warn "and the namespace behind. To fully reap them, also run:"
    log_warn "  kubectl delete namespace $NAMESPACE"

    read -p "Are you sure you want to uninstall? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        helm uninstall $RELEASE_NAME --namespace $NAMESPACE "${@:3}"
        log_info "Uninstall completed"
    else
        log_info "Uninstall cancelled"
    fi
}

# Show Helm values
helm_values() {
    log_info "Showing values for $ENVIRONMENT environment..."

    helm get values $RELEASE_NAME --namespace $NAMESPACE
}

# Show Helm status
helm_status() {
    log_info "Showing status for crAPI release..."

    helm status $RELEASE_NAME --namespace $NAMESPACE

    echo ""
    log_info "Pod status:"
    kubectl get pods -n $NAMESPACE

    echo ""
    log_info "Service status:"
    kubectl get svc -n $NAMESPACE
}

# Diff values
helm_diff() {
    log_info "Showing diff for $ENVIRONMENT environment..."

    # Requires helm-diff plugin
    if ! helm plugin list | grep -q diff; then
        log_warn "helm-diff plugin not installed. Installing..."
        helm plugin install https://github.com/databus23/helm-diff
    fi

    helm diff upgrade $RELEASE_NAME $CHART_PATH \
        --namespace $NAMESPACE \
        --values $CHART_PATH/values.yaml \
        --values $VALUES_DIR/$ENVIRONMENT.yaml \
        "${@:3}"
}

# Template rendering (for debugging)
helm_template() {
    log_info "Rendering templates for $ENVIRONMENT environment..."

    helm template $RELEASE_NAME $CHART_PATH \
        --namespace $NAMESPACE \
        --values $CHART_PATH/values.yaml \
        --values $VALUES_DIR/$ENVIRONMENT.yaml \
        "${@:3}"
}

# Rollback
helm_rollback() {
    REVISION=${3:-0}
    log_warn "Rolling back crAPI release to revision $REVISION..."

    helm rollback $RELEASE_NAME $REVISION --namespace $NAMESPACE --wait

    log_info "Rollback completed"
}

# Main function
main() {
    log_info "crAPI Helm Deployment"
    log_info "Environment: $ENVIRONMENT"
    log_info "Action: $ACTION"

    check_prerequisites
    validate_environment
    validate_context

    case $ACTION in
        install)
            helm_install "$@"
            ;;
        upgrade)
            helm_upgrade "$@"
            ;;
        uninstall|delete)
            helm_uninstall "$@"
            ;;
        values)
            helm_values
            ;;
        status)
            helm_status
            ;;
        diff)
            helm_diff "$@"
            ;;
        template)
            helm_template "$@"
            ;;
        rollback)
            helm_rollback "$@"
            ;;
        *)
            log_error "Unknown action: $ACTION"
            echo "Usage: $0 [environment] [action] [options]"
            echo "Actions:"
            echo "  install   - Install the Helm chart"
            echo "  upgrade   - Upgrade the Helm release"
            echo "  uninstall - Uninstall the Helm release"
            echo "  values    - Show current values"
            echo "  status    - Show release status"
            echo "  diff      - Show what would change"
            echo "  template  - Render templates locally"
            echo "  rollback  - Rollback to previous revision"
            echo ""
            echo "Environments:"
            ls -1 $VALUES_DIR/*.yaml 2>/dev/null | xargs -n1 basename | sed 's/.yaml//' | sed 's/^/  /'
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
