#!/usr/bin/env bash
#
# StreamSecurity GCP Integration — Cleanup Abandoned Deployment
#
# This script removes GCP resources left behind after an Infrastructure Manager
# deployment was deleted with --delete-policy=abandon (or after a partial apply).
#
# It will attempt to delete the following resources:
#   1. Cloud Function v2 (audit-log event processor + its IAM bindings)
#   2. Organization-level logging sink
#   3. Pub/Sub topic
#   4. Global secret (collection token created by Terraform)
#   5. Regional secret (and its versions)
#   6. Organization IAM bindings for the stream-security service account
#   7. Function service account
#   8. Stream-security service account (and its keys)
#
# Safety:
#   - Each resource is checked for existence before deletion
#   - The script will continue even if individual deletions fail
#   - A summary of results is displayed at the end
#
# Usage:
#   ./cleanup-abandoned-deployment.sh \
#       --project-id <PROJECT_ID> \
#       --org-id <ORGANIZATION_ID> \
#       --region <REGION>
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

###############################################################################
# Defaults (overridable via env vars)
###############################################################################
PROJECT_ID="${PROJECT_ID:-}"
ORGANIZATION_ID="${ORGANIZATION_ID:-}"
REGION="${REGION:-}"

# Resource names — must match what setup-prerequisites.sh / Terraform creates
SA_ACCOUNT_ID="${SA_ACCOUNT_ID:-stream-security}"
FUNCTION_SA_ACCOUNT_ID="${FUNCTION_SA_ACCOUNT_ID:-stream-security-function-sa}"
FUNCTION_NAME="${FUNCTION_NAME:-stream-security-events-function}"
PUBSUB_TOPIC="${PUBSUB_TOPIC:-stream-security-events-topic}"
LOGGING_SINK="${LOGGING_SINK:-stream-security-events-sink}"
REGIONAL_SECRET="${REGIONAL_SECRET:-stream-security}"
GLOBAL_SECRET="${GLOBAL_SECRET:-stream-security-collection-token}"

AUTO_CONFIRM=false

###############################################################################
# Parse CLI arguments
###############################################################################
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required options:
  --project-id      ID    GCP project used for the deployment
  --org-id          ID    GCP organization ID
  --region          NAME  GCP region where resources were deployed (e.g. us-central1)

Optional overrides:
  --sa-account-id         NAME  Main service account ID       (default: $SA_ACCOUNT_ID)
  --function-sa-id        NAME  Function service account ID   (default: $FUNCTION_SA_ACCOUNT_ID)
  --function-name         NAME  Cloud Function v2 name        (default: $FUNCTION_NAME)
  --pubsub-topic          NAME  Pub/Sub topic name            (default: $PUBSUB_TOPIC)
  --logging-sink          NAME  Logging sink name             (default: $LOGGING_SINK)
  --regional-secret       NAME  Regional secret name          (default: $REGIONAL_SECRET)
  --global-secret         NAME  Global secret name (TF token) (default: $GLOBAL_SECRET)

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
    --pubsub-topic)       PUBSUB_TOPIC="$2";            shift 2 ;;
    --logging-sink)       LOGGING_SINK="$2";            shift 2 ;;
    --regional-secret)    REGIONAL_SECRET="$2";         shift 2 ;;
    --global-secret)      GLOBAL_SECRET="$2";           shift 2 ;;
    -y|--yes)             AUTO_CONFIRM=true;            shift   ;;
    -h|--help)            usage ;;
    *) log_error "Unknown option: $1"; usage ;;
  esac
done

###############################################################################
# Validate required inputs
###############################################################################
missing=()
[[ -z "$PROJECT_ID" ]]      && missing+=("--project-id")
[[ -z "$ORGANIZATION_ID" ]] && missing+=("--org-id")
[[ -z "$REGION" ]]          && missing+=("--region")

if [[ ${#missing[@]} -gt 0 ]]; then
  log_error "Missing required parameters: ${missing[*]}"
  echo ""
  usage
fi

SA_EMAIL="${SA_ACCOUNT_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
FUNCTION_SA_EMAIL="${FUNCTION_SA_ACCOUNT_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

###############################################################################
# Discovery — check which resources exist
###############################################################################
log_step "Discovering existing resources..."

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

HAS_CLOUD_FUNCTION=false
HAS_ORG_LOGGING_SINK=false
HAS_PROJECT_LOGGING_SINK=false
HAS_PUBSUB_TOPIC=false
HAS_GLOBAL_SECRET=false
HAS_REGIONAL_SECRET=false
HAS_ORG_IAM_VIEWER=false
HAS_ORG_IAM_SECURITY_REVIEWER=false
HAS_FUNCTION_SA=false
HAS_SA=false
HAS_SA_KEY=false

check_resource "Cloud Function v2: $FUNCTION_NAME ($REGION)" \
  "gcloud functions describe '$FUNCTION_NAME' --region='$REGION' --project='$PROJECT_ID' --gen2" \
  && HAS_CLOUD_FUNCTION=true

# Auto-detect: check org-level sink first, then project-level
check_resource "Org logging sink: $LOGGING_SINK" \
  "gcloud logging sinks describe '$LOGGING_SINK' --organization='$ORGANIZATION_ID'" \
  && HAS_ORG_LOGGING_SINK=true

if [[ "$HAS_ORG_LOGGING_SINK" == false ]]; then
  check_resource "Project logging sink: $LOGGING_SINK" \
    "gcloud logging sinks describe '$LOGGING_SINK' --project='$PROJECT_ID'" \
    && HAS_PROJECT_LOGGING_SINK=true
fi

check_resource "Pub/Sub topic: $PUBSUB_TOPIC" \
  "gcloud pubsub topics describe '$PUBSUB_TOPIC' --project='$PROJECT_ID'" \
  && HAS_PUBSUB_TOPIC=true

check_resource "Global secret: $GLOBAL_SECRET" \
  "gcloud secrets describe '$GLOBAL_SECRET' --project='$PROJECT_ID'" \
  && HAS_GLOBAL_SECRET=true

# Regional secrets need list+filter — describe --location is unreliable across gcloud versions
if gcloud secrets list --project="$PROJECT_ID" --location="$REGION" \
     --filter="name~secrets/$REGIONAL_SECRET$" --format="value(name)" 2>/dev/null | grep -q .; then
  FOUND_RESOURCES+=("Regional secret: $REGIONAL_SECRET ($REGION)")
  log_info "Found: Regional secret: $REGIONAL_SECRET ($REGION)"
  HAS_REGIONAL_SECRET=true
else
  NOT_FOUND_RESOURCES+=("Regional secret: $REGIONAL_SECRET ($REGION)")
  log_warn "Not found: Regional secret: $REGIONAL_SECRET ($REGION) (skipping)"
fi

# Check org IAM bindings
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

check_resource "Function service account: $FUNCTION_SA_EMAIL" \
  "gcloud iam service-accounts describe '$FUNCTION_SA_EMAIL' --project='$PROJECT_ID'" \
  && HAS_FUNCTION_SA=true

check_resource "Service account: $SA_EMAIL" \
  "gcloud iam service-accounts describe '$SA_EMAIL' --project='$PROJECT_ID'" \
  && HAS_SA=true

if [[ "$HAS_SA" == true ]]; then
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

###############################################################################
# Summary and confirmation
###############################################################################
echo ""
if [[ ${#FOUND_RESOURCES[@]} -eq 0 ]]; then
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

# 1. Cloud Function v2 (delete first — depends on topic, SA, etc.)
if [[ "$HAS_CLOUD_FUNCTION" == true ]]; then
  delete_resource "Cloud Function v2: $FUNCTION_NAME" \
    "gcloud functions delete '$FUNCTION_NAME' --region='$REGION' --project='$PROJECT_ID' --gen2 --quiet"
fi

# 2. Logging sink (org-level or project-level — auto-detected)
if [[ "$HAS_ORG_LOGGING_SINK" == true ]]; then
  delete_resource "Org logging sink: $LOGGING_SINK" \
    "gcloud logging sinks delete '$LOGGING_SINK' --organization='$ORGANIZATION_ID' --quiet"
elif [[ "$HAS_PROJECT_LOGGING_SINK" == true ]]; then
  delete_resource "Project logging sink: $LOGGING_SINK" \
    "gcloud logging sinks delete '$LOGGING_SINK' --project='$PROJECT_ID' --quiet"
fi

# 3. Pub/Sub topic (IAM bindings on topic are removed automatically)
if [[ "$HAS_PUBSUB_TOPIC" == true ]]; then
  delete_resource "Pub/Sub topic: $PUBSUB_TOPIC" \
    "gcloud pubsub topics delete '$PUBSUB_TOPIC' --project='$PROJECT_ID' --quiet"
fi

# 4. Global secret (collection token created by Terraform)
if [[ "$HAS_GLOBAL_SECRET" == true ]]; then
  delete_resource "Global secret: $GLOBAL_SECRET" \
    "gcloud secrets delete '$GLOBAL_SECRET' --project='$PROJECT_ID' --quiet"
fi

# 5. Regional secret
if [[ "$HAS_REGIONAL_SECRET" == true ]]; then
  delete_resource "Regional secret: $REGIONAL_SECRET" \
    "gcloud secrets delete 'projects/$PROJECT_ID/locations/$REGION/secrets/$REGIONAL_SECRET' --quiet"
fi

# 6. Org IAM bindings for main SA
if [[ "$HAS_ORG_IAM_VIEWER" == true ]]; then
  delete_resource "Org IAM binding: roles/viewer" \
    "gcloud organizations remove-iam-policy-binding '$ORGANIZATION_ID' --member='serviceAccount:$SA_EMAIL' --role='roles/viewer' --quiet"
fi

if [[ "$HAS_ORG_IAM_SECURITY_REVIEWER" == true ]]; then
  delete_resource "Org IAM binding: roles/iam.securityReviewer" \
    "gcloud organizations remove-iam-policy-binding '$ORGANIZATION_ID' --member='serviceAccount:$SA_EMAIL' --role='roles/iam.securityReviewer' --quiet"
fi

# 7. Function service account
if [[ "$HAS_FUNCTION_SA" == true ]]; then
  delete_resource "Function service account: $FUNCTION_SA_EMAIL" \
    "gcloud iam service-accounts delete '$FUNCTION_SA_EMAIL' --project='$PROJECT_ID' --quiet"
fi

# 8. Main service account (keys are deleted automatically with the SA)
if [[ "$HAS_SA" == true ]]; then
  delete_resource "Service account: $SA_EMAIL" \
    "gcloud iam service-accounts delete '$SA_EMAIL' --project='$PROJECT_ID' --quiet"
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
log_info "Cleanup completed successfully!"
echo ""
