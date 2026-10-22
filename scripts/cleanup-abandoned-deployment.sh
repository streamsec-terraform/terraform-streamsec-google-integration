#!/usr/bin/env bash
#
# StreamSecurity GCP Integration — Cleanup Abandoned Deployment
#
# This script removes GCP resources left behind after an Infrastructure Manager
# deployment was deleted with --delete-policy=abandon (or after a partial apply).
#
# It will attempt to delete the following resources:
#   1. Organization IAM bindings for the stream-security service account
#   2. Cloud Function v2 (audit-log event processor + its IAM bindings)
#   3. Organization-level or project-level logging sink
#   4. Pub/Sub topic
#   5. Global secret (collection token created by Terraform)
#   6. Regional secret (and its versions)
#   7. Function service account
#   8. Stream-security service account (and its keys)
#   9. Infrastructure Manager SA IAM bindings (ops role, project role, config.agent)
#  10. Infrastructure Manager service account
#  11. Custom IAM roles (ops role at org or project, project resources role)
#
# Not the GKE audit logs resources (enable_gke_logs): their names end with a random suffix
# that only the deleted deployment knew. Delete them by hand.
# --only <kinds> limits it to some of 2-8 (the kinds in lib/integration-resources.sh),
# which is how setup-prerequisites.sh's leftover check points here.
#
# Safety:
#   - Each resource is checked for existence before deletion
#   - The script will continue even if individual deletions fail
#   - A summary of results is displayed at the end
#
# Usage:
#   ./cleanup-abandoned-deployment.sh \
#       --project-id <PROJECT_ID> \
#       --region <REGION> \
#       [--org-id <ORGANIZATION_ID>] \
#       [--only <kind>[,<kind>...]]
#
set -euo pipefail

###############################################################################
# Colours / helpers
###############################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Colour

log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()    { echo -e "\n${CYAN}==>${NC} $*"; }

# Piped in, there is no script directory: never fall back to the current one.
IR_LIB=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  IR_LIB="$(CDPATH="" cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd)/lib/integration-resources.sh"
fi
if [[ -z "$IR_LIB" || ! -f "$IR_LIB" ]]; then
  log_error "lib/integration-resources.sh not found next to this script. Run it from a clone of the repository."
  exit 1
fi
# Resource names (SA_ACCOUNT_ID, PUBSUB_TOPIC, ...) and how to check and delete each.
# shellcheck source=lib/integration-resources.sh
source "$IR_LIB"

###############################################################################
# Defaults (overridable via env vars)
###############################################################################
PROJECT_ID="${PROJECT_ID:-}"
ORGANIZATION_ID="${ORGANIZATION_ID:-}"
REGION="${REGION:-}"
ONLY_KINDS=""
ONLY_GIVEN=false

# Infrastructure Manager SA and role names (from setup-prerequisites.sh)
IM_SA_NAME="${IM_SA_NAME:-StreamSecurityInfraManagerSa}"
OPS_ROLE_ID="${OPS_ROLE_ID:-StreamSecurityInfraManagerOpsRole}"
PROJECT_ROLE_ID="${PROJECT_ROLE_ID:-StreamSecurityInfraManagerProjectRole}"

AUTO_CONFIRM=false

###############################################################################
# Parse CLI arguments
###############################################################################
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required options:
  --project-id      ID    GCP project used for the deployment
  --region          NAME  GCP region where resources were deployed (e.g. us-central1)

Optional:
  --org-id          ID    GCP organization ID (required only for org-level cleanup)
  --only            KINDS Delete only these comma-separated kinds, and none of the
                          Infrastructure Manager SA, its bindings or the custom roles:
                          ${IR_KINDS[*]}

Optional overrides:
  --sa-account-id         NAME  Main service account ID       (default: $SA_ACCOUNT_ID)
  --function-sa-id        NAME  Function service account ID   (default: $FUNCTION_SA_ACCOUNT_ID)
  --function-name         NAME  Cloud Function v2 name        (default: $FUNCTION_NAME)
  --pubsub-topic          NAME  Pub/Sub topic name            (default: $PUBSUB_TOPIC)
  --logging-sink          NAME  Logging sink name             (default: $LOGGING_SINK)
  --regional-secret       NAME  Regional secret name          (default: $REGIONAL_SECRET)
  --global-secret         NAME  Global secret name (TF token) (default: $GLOBAL_SECRET)
  --im-sa-name            NAME  Infra Manager SA name         (default: $IM_SA_NAME)
  --ops-role-id           NAME  Ops custom role ID            (default: $OPS_ROLE_ID)
  --project-role-id       NAME  Project resources role ID     (default: $PROJECT_ROLE_ID)

  -y, --yes               Skip confirmation prompts
  -h, --help              Show this help message and exit

Environment variables PROJECT_ID, ORGANIZATION_ID, and REGION are also accepted.
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)         PROJECT_ID="$2";              shift 2 ;;
    --org-id)             ORGANIZATION_ID="$2";         shift 2 ;;
    --region)             REGION="$2";                  shift 2 ;;
    --sa-account-id)      SA_ACCOUNT_ID="$2";           shift 2 ;;
    --function-sa-id)     FUNCTION_SA_ACCOUNT_ID="$2";  shift 2 ;;
    --function-name)      FUNCTION_NAME="$2";           shift 2 ;;
    --only)               ONLY_KINDS="${2// /}"; ONLY_GIVEN=true; shift 2 ;;
    --pubsub-topic)       PUBSUB_TOPIC="$2";            shift 2 ;;
    --logging-sink)       LOGGING_SINK="$2";            shift 2 ;;
    --regional-secret)    REGIONAL_SECRET="$2";         shift 2 ;;
    --global-secret)      GLOBAL_SECRET="$2";           shift 2 ;;
    --im-sa-name)         IM_SA_NAME="$2";              shift 2 ;;
    --ops-role-id)        OPS_ROLE_ID="$2";             shift 2 ;;
    --project-role-id)    PROJECT_ROLE_ID="$2";         shift 2 ;;
    -y|--yes)             AUTO_CONFIRM=true;            shift   ;;
    -h|--help)            usage ;;
    *) log_error "Unknown option: $1"; usage ;;
  esac
done

###############################################################################
# Validate required inputs
###############################################################################
missing=()
[[ -z "$PROJECT_ID" ]] && missing+=("--project-id")
[[ -z "$REGION" ]]     && missing+=("--region")

if [[ ${#missing[@]} -gt 0 ]]; then
  log_error "Missing required parameters: ${missing[*]}"
  echo ""
  usage
fi

# REGION ends up in an API endpoint's host name.
if [[ ! "$REGION" =~ ^[a-z]+-[a-z]+[0-9]+$ ]]; then
  log_error "Invalid --region '$REGION' (expected e.g. us-central1)."
  exit 1
fi

if [[ "$ONLY_GIVEN" == true ]]; then
  if [[ -z "${ONLY_KINDS//,/}" ]]; then
    log_error "--only needs at least one kind (${IR_KINDS[*]})."
    exit 1
  fi
  for kind in ${ONLY_KINDS//,/ }; do
    if ! ir_is_kind "$kind"; then
      log_error "Unknown kind in --only: '$kind' (expected: ${IR_KINDS[*]})"
      exit 1
    fi
  done
  if [[ ",$ONLY_KINDS," == *",org-sink,"* && -z "$ORGANIZATION_ID" ]]; then
    log_error "--only org-sink needs --org-id."
    exit 1
  fi
fi

# Whether --only (if given) includes this kind.
selected() { [[ "$ONLY_GIVEN" != true || ",$ONLY_KINDS," == *",$1,"* ]]; }

SA_EMAIL="${SA_ACCOUNT_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
IM_SA_EMAIL="${IM_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

###############################################################################
# Discovery — check which resources exist
###############################################################################
log_step "Discovering existing resources..."
if [[ "$ONLY_GIVEN" != true ]]; then
  log_info "GKE audit logs resources (enable_gke_logs, names with a random suffix) are not checked: delete them by hand."
fi

FOUND_RESOURCES=()
NOT_FOUND_RESOURCES=()

check_resource() {
  local name="$1"
  local check_cmd="$2"

  if eval "$check_cmd" &>/dev/null; then
    FOUND_RESOURCES+=("$name")
    log_info "Found: $name"
    return 0
  else
    NOT_FOUND_RESOURCES+=("$name")
    log_warn "Not found: $name (skipping)"
    return 1
  fi
}

HAS_ORG_IAM_VIEWER=false
HAS_ORG_IAM_SECURITY_REVIEWER=false
FOUND_KINDS=()
UNCHECKED_RESOURCES=()

kind_found() { [[ " ${FOUND_KINDS[*]-} " == *" $1 "* ]]; }

for kind in "${IR_KINDS[@]}"; do
  selected "$kind" || continue
  # Auto-detect the sink: org level first (only with an org ID), then project level; --only takes both as asked.
  if [[ "$kind" == org-sink && -z "$ORGANIZATION_ID" ]] ||
      { [[ "$kind" == project-sink && "$ONLY_GIVEN" != true ]] && kind_found org-sink; }; then
    continue
  fi
  label=$(ir_label "$kind")
  exists_rc=0
  ir_exists "$kind" || exists_rc=$?
  if [[ $exists_rc -eq 0 ]]; then
    FOUND_KINDS+=("$kind")
    FOUND_RESOURCES+=("$label")
    log_info "Found: $label"
  elif [[ $exists_rc -eq 1 ]]; then
    NOT_FOUND_RESOURCES+=("$label")
    log_warn "Not found: $label (skipping)"
  else
    UNCHECKED_RESOURCES+=("$label")
    log_warn "Could not check: $label (skipping)"
  fi
done

# Check org IAM bindings (only if org-id provided)
if [[ -n "$ORGANIZATION_ID" && "$ONLY_GIVEN" != true ]]; then
  ORG_IAM_BINDINGS=$(gcloud organizations get-iam-policy "$ORGANIZATION_ID" \
    --flatten="bindings[].members" \
    --filter="bindings.members:serviceAccount:$SA_EMAIL" \
    --format="value(bindings.role)" 2>/dev/null || echo "")

  if echo "$ORG_IAM_BINDINGS" | grep -q "roles/viewer"; then
    FOUND_RESOURCES+=("Org IAM binding: roles/viewer for $SA_EMAIL")
    log_info "Found: Org IAM binding: roles/viewer for $SA_EMAIL"
    HAS_ORG_IAM_VIEWER=true
  else
    NOT_FOUND_RESOURCES+=("Org IAM binding: roles/viewer for $SA_EMAIL")
    log_warn "Not found: Org IAM binding: roles/viewer (skipping)"
  fi

  if echo "$ORG_IAM_BINDINGS" | grep -q "roles/iam.securityReviewer"; then
    FOUND_RESOURCES+=("Org IAM binding: roles/iam.securityReviewer for $SA_EMAIL")
    log_info "Found: Org IAM binding: roles/iam.securityReviewer for $SA_EMAIL"
    HAS_ORG_IAM_SECURITY_REVIEWER=true
  else
    NOT_FOUND_RESOURCES+=("Org IAM binding: roles/iam.securityReviewer for $SA_EMAIL")
    log_warn "Not found: Org IAM binding: roles/iam.securityReviewer (skipping)"
  fi
fi

HAS_SA_KEY=false
if kind_found sa; then
  SA_KEYS=$(gcloud iam service-accounts keys list \
    --iam-account="$SA_EMAIL" \
    --managed-by=user \
    --format="value(name)" 2>/dev/null || echo "")
  if [[ -n "$SA_KEYS" ]]; then
    FOUND_RESOURCES+=("Service account keys for $SA_EMAIL")
    log_info "Found: Service account user-managed keys for $SA_EMAIL"
    HAS_SA_KEY=true
  fi
fi

# The Infrastructure Manager SA and the custom roles (never with --only)
HAS_IM_SA=false
HAS_OPS_ROLE_ORG=false
HAS_OPS_ROLE_PROJECT=false
HAS_PROJECT_ROLE=false
if [[ "$ONLY_GIVEN" != true ]]; then
  check_resource "IM service account: $IM_SA_EMAIL" \
    "gcloud iam service-accounts describe '$IM_SA_EMAIL' --project='$PROJECT_ID'" \
    && HAS_IM_SA=true

  # Ops role: org level first if org-id provided, then project level
  if [[ -n "$ORGANIZATION_ID" ]]; then
    check_resource "Ops role (org): $OPS_ROLE_ID" \
      "gcloud iam roles describe '$OPS_ROLE_ID' --organization='$ORGANIZATION_ID'" \
      && HAS_OPS_ROLE_ORG=true
  fi

  if [[ "$HAS_OPS_ROLE_ORG" == false ]]; then
    check_resource "Ops role (project): $OPS_ROLE_ID" \
      "gcloud iam roles describe '$OPS_ROLE_ID' --project='$PROJECT_ID'" \
      && HAS_OPS_ROLE_PROJECT=true
  fi

  # Project resources role (always project-level)
  check_resource "Project resources role: $PROJECT_ROLE_ID" \
    "gcloud iam roles describe '$PROJECT_ROLE_ID' --project='$PROJECT_ID'" \
    && HAS_PROJECT_ROLE=true
fi

# Check for IM SA IAM bindings (ops role + config.agent at org or project)
HAS_IM_OPS_ROLE_BINDING_ORG=false
HAS_IM_OPS_ROLE_BINDING_PROJECT=false
HAS_IM_PROJECT_ROLE_BINDING=false
HAS_IM_CONFIG_AGENT_ORG=false
HAS_IM_CONFIG_AGENT_PROJECT=false

if [[ "$HAS_IM_SA" == true ]]; then
  # Check org-level bindings (only if org-id provided)
  if [[ -n "$ORGANIZATION_ID" ]]; then
    IM_ORG_BINDINGS=$(gcloud organizations get-iam-policy "$ORGANIZATION_ID" \
      --flatten="bindings[].members" \
      --filter="bindings.members:serviceAccount:$IM_SA_EMAIL" \
      --format="value(bindings.role)" 2>/dev/null || echo "")

    if echo "$IM_ORG_BINDINGS" | grep -q "roles/$OPS_ROLE_ID\|organizations/.*/roles/$OPS_ROLE_ID"; then
      FOUND_RESOURCES+=("Org IAM binding: ops role for $IM_SA_EMAIL")
      log_info "Found: Org IAM binding: ops role for $IM_SA_EMAIL"
      HAS_IM_OPS_ROLE_BINDING_ORG=true
    fi

    if echo "$IM_ORG_BINDINGS" | grep -q "roles/config.agent"; then
      FOUND_RESOURCES+=("Org IAM binding: roles/config.agent for $IM_SA_EMAIL")
      log_info "Found: Org IAM binding: roles/config.agent for $IM_SA_EMAIL"
      HAS_IM_CONFIG_AGENT_ORG=true
    fi
  fi

  # Check project-level bindings
  IM_PROJECT_BINDINGS=$(gcloud projects get-iam-policy "$PROJECT_ID" \
    --flatten="bindings[].members" \
    --filter="bindings.members:serviceAccount:$IM_SA_EMAIL" \
    --format="value(bindings.role)" 2>/dev/null || echo "")

  if echo "$IM_PROJECT_BINDINGS" | grep -q "roles/$OPS_ROLE_ID\|projects/.*/roles/$OPS_ROLE_ID"; then
    FOUND_RESOURCES+=("Project IAM binding: ops role for $IM_SA_EMAIL")
    log_info "Found: Project IAM binding: ops role for $IM_SA_EMAIL"
    HAS_IM_OPS_ROLE_BINDING_PROJECT=true
  fi

  if echo "$IM_PROJECT_BINDINGS" | grep -q "roles/$PROJECT_ROLE_ID\|projects/.*/roles/$PROJECT_ROLE_ID"; then
    FOUND_RESOURCES+=("Project IAM binding: project role for $IM_SA_EMAIL")
    log_info "Found: Project IAM binding: project role for $IM_SA_EMAIL"
    HAS_IM_PROJECT_ROLE_BINDING=true
  fi

  if echo "$IM_PROJECT_BINDINGS" | grep -q "roles/config.agent"; then
    FOUND_RESOURCES+=("Project IAM binding: roles/config.agent for $IM_SA_EMAIL")
    log_info "Found: Project IAM binding: roles/config.agent for $IM_SA_EMAIL"
    HAS_IM_CONFIG_AGENT_PROJECT=true
  fi
fi

###############################################################################
# Summary and confirmation
###############################################################################
echo ""
if [[ ${#FOUND_RESOURCES[@]} -eq 0 ]]; then
  if [[ ${#UNCHECKED_RESOURCES[@]} -gt 0 ]]; then
    log_error "Found nothing to delete, but could not check: ${UNCHECKED_RESOURCES[*]}"
    exit 1
  fi
  log_info "No resources found to clean up. Nothing to do."
  exit 0
fi

echo "============================================================"
log_info "Resources to delete:"
echo "============================================================"
echo ""
for resource in "${FOUND_RESOURCES[@]}"; do
  echo "  • $resource"
done
echo ""

if [[ ${#NOT_FOUND_RESOURCES[@]} -gt 0 ]]; then
  log_warn "Resources already gone (will be skipped):"
  for resource in "${NOT_FOUND_RESOURCES[@]}"; do
    echo "  • $resource"
  done
  echo ""
fi

# Check if any org-level resources will be deleted
HAS_ORG_LEVEL_DELETIONS=false
if kind_found org-sink || \
   [[ "$HAS_ORG_IAM_VIEWER" == true ]] || \
   [[ "$HAS_ORG_IAM_SECURITY_REVIEWER" == true ]] || \
   [[ "$HAS_IM_OPS_ROLE_BINDING_ORG" == true ]] || \
   [[ "$HAS_IM_CONFIG_AGENT_ORG" == true ]] || \
   [[ "$HAS_OPS_ROLE_ORG" == true ]]; then
  HAS_ORG_LEVEL_DELETIONS=true
fi

# Show red warning banner for org-level deletions
if [[ "$HAS_ORG_LEVEL_DELETIONS" == true ]]; then
  echo ""
  echo -e "${RED}╔═══════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║                                                                   ║${NC}"
  echo -e "${RED}║                   ⚠️  ORGANIZATION-LEVEL DELETION  ⚠️             ║${NC}"
  echo -e "${RED}║                                                                   ║${NC}"
  echo -e "${RED}║   This operation will delete ORGANIZATION-LEVEL resources that    ║${NC}"
  echo -e "${RED}║   may affect the entire organization, not just this project!      ║${NC}"
  echo -e "${RED}║   Resources include: logging sinks, IAM bindings, custom roles    ║${NC}"
  echo -e "${RED}║   Please review the list above carefully before proceeding.       ║${NC}"
  echo -e "${RED}║                                                                   ║${NC}"
  echo -e "${RED}╚═══════════════════════════════════════════════════════════════════╝${NC}"
  echo ""

  if [[ "$AUTO_CONFIRM" != true ]]; then
    read -r -p "$(echo -e ${RED}Type 'DELETE-ORG-RESOURCES' to confirm org-level deletion:${NC} )" org_confirm
    if [[ "$org_confirm" != "DELETE-ORG-RESOURCES" ]]; then
      log_warn "Org-level deletion not confirmed. Aborted."
      exit 1
    fi
    echo ""
  fi
fi

if [[ "$AUTO_CONFIRM" != true ]]; then
  read -r -p "Proceed with cleanup? [y/N] " response
  case "$response" in
    [yY][eE][sS]|[yY]) ;;
    *) log_warn "Aborted."; exit 1 ;;
  esac
fi

###############################################################################
# Cleanup
###############################################################################
DELETED=()
FAILED=()

delete_resource() {
  local name="$1"
  local delete_cmd="$2"

  log_info "Deleting: $name ..."
  if eval "$delete_cmd" 2>&1; then
    DELETED+=("$name")
    log_info "✓ Deleted: $name"
  else
    FAILED+=("$name")
    log_error "✗ Failed to delete: $name"
  fi
}

# 1. Org IAM bindings for main SA (while its member name still resolves)
if [[ "$HAS_ORG_IAM_VIEWER" == true ]]; then
  delete_resource "Org IAM binding: roles/viewer" \
    "gcloud organizations remove-iam-policy-binding '$ORGANIZATION_ID' --member='serviceAccount:$SA_EMAIL' --role='roles/viewer' --quiet"
fi

if [[ "$HAS_ORG_IAM_SECURITY_REVIEWER" == true ]]; then
  delete_resource "Org IAM binding: roles/iam.securityReviewer" \
    "gcloud organizations remove-iam-policy-binding '$ORGANIZATION_ID' --member='serviceAccount:$SA_EMAIL' --role='roles/iam.securityReviewer' --quiet"
fi

# 2-8. Module resources, in IR_KINDS (dependency) order
for kind in ${FOUND_KINDS[@]+"${FOUND_KINDS[@]}"}; do
  delete_resource "$(ir_label "$kind")" "ir_delete $kind"
done

# 9. IM SA IAM bindings (remove before deleting the SA)
if [[ "$HAS_IM_OPS_ROLE_BINDING_ORG" == true ]]; then
  delete_resource "Org IAM binding: ops role for $IM_SA_EMAIL" \
    "gcloud organizations remove-iam-policy-binding '$ORGANIZATION_ID' --member='serviceAccount:$IM_SA_EMAIL' --role='organizations/$ORGANIZATION_ID/roles/$OPS_ROLE_ID' --quiet"
fi

if [[ "$HAS_IM_CONFIG_AGENT_ORG" == true ]]; then
  delete_resource "Org IAM binding: roles/config.agent for $IM_SA_EMAIL" \
    "gcloud organizations remove-iam-policy-binding '$ORGANIZATION_ID' --member='serviceAccount:$IM_SA_EMAIL' --role='roles/config.agent' --quiet"
fi

if [[ "$HAS_IM_OPS_ROLE_BINDING_PROJECT" == true ]]; then
  delete_resource "Project IAM binding: ops role for $IM_SA_EMAIL" \
    "gcloud projects remove-iam-policy-binding '$PROJECT_ID' --member='serviceAccount:$IM_SA_EMAIL' --role='projects/$PROJECT_ID/roles/$OPS_ROLE_ID' --quiet"
fi

if [[ "$HAS_IM_PROJECT_ROLE_BINDING" == true ]]; then
  delete_resource "Project IAM binding: project role for $IM_SA_EMAIL" \
    "gcloud projects remove-iam-policy-binding '$PROJECT_ID' --member='serviceAccount:$IM_SA_EMAIL' --role='projects/$PROJECT_ID/roles/$PROJECT_ROLE_ID' --quiet"
fi

if [[ "$HAS_IM_CONFIG_AGENT_PROJECT" == true ]]; then
  delete_resource "Project IAM binding: roles/config.agent for $IM_SA_EMAIL" \
    "gcloud projects remove-iam-policy-binding '$PROJECT_ID' --member='serviceAccount:$IM_SA_EMAIL' --role='roles/config.agent' --quiet"
fi

# 10. IM service account
if [[ "$HAS_IM_SA" == true ]]; then
  delete_resource "IM service account: $IM_SA_EMAIL" \
    "gcloud iam service-accounts delete '$IM_SA_EMAIL' --project='$PROJECT_ID' --quiet"
fi

# 11. Custom roles (delete after removing all bindings)
if [[ "$HAS_OPS_ROLE_ORG" == true ]]; then
  delete_resource "Ops role (org): $OPS_ROLE_ID" \
    "gcloud iam roles delete '$OPS_ROLE_ID' --organization='$ORGANIZATION_ID' --quiet"
fi

if [[ "$HAS_OPS_ROLE_PROJECT" == true ]]; then
  delete_resource "Ops role (project): $OPS_ROLE_ID" \
    "gcloud iam roles delete '$OPS_ROLE_ID' --project='$PROJECT_ID' --quiet"
fi

if [[ "$HAS_PROJECT_ROLE" == true ]]; then
  delete_resource "Project resources role: $PROJECT_ROLE_ID" \
    "gcloud iam roles delete '$PROJECT_ROLE_ID' --project='$PROJECT_ID' --quiet"
fi

###############################################################################
# Summary
###############################################################################
echo ""
echo "============================================================"
log_info "Cleanup Summary"
echo "============================================================"
echo ""

if [[ ${#DELETED[@]} -gt 0 ]]; then
  log_info "Successfully deleted (${#DELETED[@]}):"
  for resource in "${DELETED[@]}"; do
    echo "  ✓ $resource"
  done
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo ""
  log_error "Failed to delete (${#FAILED[@]}):"
  for resource in "${FAILED[@]}"; do
    echo "  ✗ $resource"
  done
  echo ""
  log_warn "You may need to delete the failed resources manually."
  exit 1
fi

if [[ ${#NOT_FOUND_RESOURCES[@]} -gt 0 ]]; then
  echo ""
  log_info "Already gone (${#NOT_FOUND_RESOURCES[@]}):"
  for resource in "${NOT_FOUND_RESOURCES[@]}"; do
    echo "  - $resource"
  done
fi

echo ""
if [[ ${#UNCHECKED_RESOURCES[@]} -gt 0 ]]; then
  echo ""
  log_error "Could not check (${#UNCHECKED_RESOURCES[@]}), so they may still exist:"
  for resource in "${UNCHECKED_RESOURCES[@]}"; do
    echo "  ? $resource"
  done
  exit 1
fi

log_info "Cleanup completed successfully!"
echo ""
