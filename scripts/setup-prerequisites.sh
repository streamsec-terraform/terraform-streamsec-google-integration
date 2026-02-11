#!/usr/bin/env bash
#
# StreamSecurity GCP Integration — Prerequisites Setup Script
#
# This script automates the manual pre-integration steps documented at:
#   https://docs.streamsec.io/docs/integrations-cloud-gcp
#
# It performs the following:
#   1. Enables all required GCP APIs in the target project.
#   2. Creates a custom organization-level IAM role with the permissions
#      required by the Infrastructure Manager deployment.
#   3. Creates a service account in the target project for Infrastructure Manager.
#   4. Grants the custom role and the Cloud Infrastructure Manager Agent role
#      to the service account at the organization level.
#   5. Creates the StreamSecurity credentials secret in Secret Manager.
#   6. Creates an Infrastructure Manager preview deployment and waits for
#      it to complete.
#
# If the preview succeeds, the script provides instructions to create the
# actual deployment via the GCP Console or gcloud CLI.
#
# Idempotency and Safety:
#   - The script checks for existing resources before creating them
#   - It's safe to re-run the script multiple times
#   - Permission checks use timeouts to avoid hanging on slow API responses
#   - Resource creation steps do NOT have aggressive timeouts to prevent
#     partial creation and ensure atomicity
#
# Prerequisites:
#   - gcloud CLI installed and authenticated.
#   - The authenticated user must have sufficient permissions (see below).
#   - The organization policy "constraints/iam.disableServiceAccountKeyCreation"
#     is automatically disabled at the project level by this script (Step 1).
#     The authenticated user needs 'orgpolicy.policy.set' permission or
#     roles/orgpolicy.policyAdmin on the project.
#   - The script checks whether the authenticated user has
#     'roles/orgpolicy.policyAdmin' and, if missing, automatically grants it
#     at the organization level (requires sufficient privileges, e.g. roles/owner).
#
# Required Permissions:
#   Organization level (choose one):
#     • roles/owner (full access - simplest option)
#     • roles/iam.organizationRoleAdmin + roles/resourcemanager.organizationAdmin
#       (both roles required!)
#
#   Important: Organization Administrator alone is NOT sufficient!
#     - roles/resourcemanager.organizationAdmin → Can set IAM policies
#     - roles/iam.organizationRoleAdmin → Can create custom roles
#     You need BOTH roles (or just use roles/owner)
#
#   Project level (choose one):
#     • roles/owner (full access - simplest option)
#     • roles/editor (broad permissions - recommended)
#     • roles/serviceusage.serviceUsageAdmin + roles/iam.serviceAccountAdmin +
#       roles/secretmanager.admin + roles/config.admin (minimal set)
#
#   The script will validate permissions before making changes.
#
# Usage:
#   ./setup-prerequisites.sh \
#       --project-id <PROJECT_ID> \
#       --org-id <ORGANIZATION_ID> \
#       --region <REGION> \
#       --streamsec-host <HOST> \
#       --workspace-id <WORKSPACE_ID> \
#       --api-token <API_TOKEN>
#
# All flags also accept environment variables (see defaults section below).
#
set -euo pipefail

###############################################################################
# Colours / helpers
###############################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Colour

log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()    { echo -e "\n${CYAN}==>${NC} $*"; }

# Confirmation helper for critical steps
confirm_step() {
  local step_name="$1"
  local exit_code="${2:-$?}"

  if [[ "$AUTO_CONFIRM" == true ]]; then
    return 0
  fi

  echo ""
  if [[ $exit_code -ne 0 ]]; then
    log_error "Step '$step_name' encountered an error (exit code: $exit_code)"
    echo ""
    read -r -p "Do you want to continue anyway? [y/N] " response
    case "$response" in
      [yY][eE][sS]|[yY])
        log_warn "Continuing despite error..."
        return 0
        ;;
      *)
        log_error "Aborted by user."
        exit 1
        ;;
    esac
  else
    log_ok "✓ Step '$step_name' completed successfully"
  fi
}

###############################################################################
# Defaults (overridable via env vars)
###############################################################################
PROJECT_ID="${PROJECT_ID:-}"
ORGANIZATION_ID="${ORGANIZATION_ID:-}"
REGION="${REGION:-}"
STREAMSEC_HOST="${STREAMSEC_HOST:-}"
WORKSPACE_ID="${WORKSPACE_ID:-}"
API_TOKEN="${API_TOKEN:-}"

# Customisable names – sensible defaults matching the docs
CUSTOM_ROLE_ID="${CUSTOM_ROLE_ID:-StreamSecurityInfraManagerRole}"
CUSTOM_ROLE_TITLE="${CUSTOM_ROLE_TITLE:-Stream Security Infra Manager Custom Role}"
SA_NAME="${SA_NAME:-StreamSecurityInfraManagerSa}"
SA_DISPLAY_NAME="${SA_DISPLAY_NAME:-Stream Security Infra Manager SA}"
SECRET_NAME="${SECRET_NAME:-streamsec-credentials}"

# Infrastructure Manager deployment settings
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-streamsec-integration}"
GIT_REPO="https://github.com/streamsec-terraform/terraform-streamsec-google-integration"
GIT_DIRECTORY="infrastructure-manager"
ORG_LEVEL_SINK="${ORG_LEVEL_SINK:-true}"
SKIP_PERMISSION_CHECK="${SKIP_PERMISSION_CHECK:-false}"

# Timeout for permission check commands (in seconds)
# Note: Resource creation steps do NOT have aggressive timeouts to avoid partial creation
PERMISSION_CHECK_TIMEOUT="${PERMISSION_CHECK_TIMEOUT:-15}"

# Starting step (1-6) - allows resuming from a specific step
START_FROM_STEP="${START_FROM_STEP:-1}"

###############################################################################
# Parse CLI arguments
###############################################################################
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required options:
  --project-id      ID    GCP project for the Infrastructure Manager deployment
  --org-id          ID    GCP organization ID
  --region          NAME  GCP region for resources (e.g. us-central1)
  --streamsec-host  HOST  StreamSecurity host (e.g. <your-org>.streamsec.io)
  --workspace-id    ID    StreamSecurity workspace ID
  --api-token       TOKEN StreamSecurity API token

Optional overrides:
  --custom-role-id  ID    Custom role ID          (default: $CUSTOM_ROLE_ID)
  --sa-name         NAME  Service account name    (default: $SA_NAME)
  --secret-name     NAME  Secret Manager secret   (default: $SECRET_NAME)

Infrastructure Manager options:
  --deployment-name NAME  Deployment name         (default: $DEPLOYMENT_NAME)
  --single-project        Use project-level log sinks instead of org-level
  --start-from-step NUM   Start from step NUM (1-6, default: 1) - useful for resuming

  -h, --help                  Show this help message and exit
  -y, --yes                   Skip confirmation prompts
  --skip-permission-check     Skip permission validation (not recommended)

Environment variables PROJECT_ID, ORGANIZATION_ID, REGION, STREAMSEC_HOST,
WORKSPACE_ID, and API_TOKEN are also accepted.
EOF
  exit 0
}

AUTO_CONFIRM=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)           PROJECT_ID="$2";            shift 2 ;;
    --org-id)               ORGANIZATION_ID="$2";       shift 2 ;;
    --region)               REGION="$2";                shift 2 ;;
    --streamsec-host)       STREAMSEC_HOST="$2";        shift 2 ;;
    --workspace-id)         WORKSPACE_ID="$2";          shift 2 ;;
    --api-token)            API_TOKEN="$2";             shift 2 ;;
    --custom-role-id)       CUSTOM_ROLE_ID="$2";        shift 2 ;;
    --sa-name)              SA_NAME="$2";               shift 2 ;;
    --secret-name)          SECRET_NAME="$2";           shift 2 ;;
    --deployment-name)      DEPLOYMENT_NAME="$2";       shift 2 ;;
    --start-from-step)      START_FROM_STEP="$2";       shift 2 ;;
    --single-project)       ORG_LEVEL_SINK=false;       shift   ;;
    --skip-permission-check) SKIP_PERMISSION_CHECK=true; shift   ;;
    -y|--yes)               AUTO_CONFIRM=true;          shift   ;;
    -h|--help)              usage ;;
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
[[ -z "$STREAMSEC_HOST" ]]  && missing+=("--streamsec-host")
[[ -z "$WORKSPACE_ID" ]]    && missing+=("--workspace-id")
[[ -z "$API_TOKEN" ]]       && missing+=("--api-token")

if [[ ${#missing[@]} -gt 0 ]]; then
  log_error "Missing required parameters: ${missing[*]}"
  echo ""
  usage
fi

# Validate START_FROM_STEP
if [[ ! "$START_FROM_STEP" =~ ^[1-6]$ ]]; then
  log_error "Invalid --start-from-step value: $START_FROM_STEP (must be 1-6)"
  exit 1
fi

if [[ "$START_FROM_STEP" -gt 1 ]]; then
  log_warn "Starting from step $START_FROM_STEP - skipping earlier steps"
  log_warn "Make sure the skipped steps were completed successfully!"
  echo ""
fi

###############################################################################
# Permission checks
###############################################################################
if [[ "$SKIP_PERMISSION_CHECK" != true ]]; then
  log_step "Validating permissions..."

  PERMISSION_ERRORS=()
  PERMISSION_WARNINGS=()

  # Test organization-level permissions
  log_info "Checking organization-level permissions..."

  # Check if we can read org IAM policy
  if timeout "$PERMISSION_CHECK_TIMEOUT" gcloud organizations get-iam-policy "$ORGANIZATION_ID" --format="value(bindings)" &>/dev/null; then
    log_ok "✓ Can read organization IAM policy"
  else
    EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 124 ]]; then
      PERMISSION_WARNINGS+=("⚠️  Timeout checking organization IAM policy (slow API response)")
    else
      PERMISSION_ERRORS+=("❌ Cannot read organization IAM policy (required: resourcemanager.organizations.getIamPolicy)")
    fi
  fi

  # Check if we can describe/create roles at org level
  if timeout "$PERMISSION_CHECK_TIMEOUT" gcloud iam roles describe "$CUSTOM_ROLE_ID" --organization="$ORGANIZATION_ID" &>/dev/null; then
    log_ok "✓ Custom role already exists (will update if needed)"
  else
    EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 124 ]]; then
      PERMISSION_WARNINGS+=("⚠️  Timeout checking custom role existence (slow API response)")
    else
      # Try to test role creation permission by checking if we have the permission
      # We can't actually test this without creating a role, so we'll check the user's roles
      CURRENT_USER=$(timeout 5 gcloud config get-value account 2>/dev/null || echo "unknown")
      if [[ "$CURRENT_USER" != "unknown" ]]; then
        USER_ORG_ROLES=$(timeout "$PERMISSION_CHECK_TIMEOUT" gcloud organizations get-iam-policy "$ORGANIZATION_ID" \
          --flatten="bindings[].members" \
          --filter="bindings.members:user:$CURRENT_USER OR bindings.members:serviceAccount:$CURRENT_USER" \
          --format="value(bindings.role)" 2>/dev/null || echo "")

        # Check for role creation permissions (need iam.organizationRoleAdmin, NOT just organizationAdmin)
        HAS_OWNER=$(echo "$USER_ORG_ROLES" | grep -q "roles/owner" && echo "true" || echo "false")
        HAS_ROLE_ADMIN=$(echo "$USER_ORG_ROLES" | grep -q "roles/iam.organizationRoleAdmin" && echo "true" || echo "false")
        HAS_ORG_ADMIN=$(echo "$USER_ORG_ROLES" | grep -q "roles/resourcemanager.organizationAdmin" && echo "true" || echo "false")

        if [[ "$HAS_OWNER" == "true" ]]; then
          log_ok "✓ Have Owner role (can create custom roles and set IAM policies)"
        elif [[ "$HAS_ROLE_ADMIN" == "true" && "$HAS_ORG_ADMIN" == "true" ]]; then
          log_ok "✓ Have Organization Role Administrator + Organization Administrator roles"
        elif [[ "$HAS_ROLE_ADMIN" == "true" ]]; then
          log_ok "✓ Have Organization Role Administrator role (can create custom roles)"
          PERMISSION_WARNINGS+=("⚠️  Missing roles/resourcemanager.organizationAdmin (may not be able to set IAM policies)")
        elif [[ "$HAS_ORG_ADMIN" == "true" ]]; then
          PERMISSION_ERRORS+=("❌ Have Organization Administrator role but missing roles/iam.organizationRoleAdmin (CANNOT create custom roles)")
        else
          PERMISSION_ERRORS+=("❌ Missing both roles/iam.organizationRoleAdmin and roles/resourcemanager.organizationAdmin")
        fi
      else
        PERMISSION_WARNINGS+=("⚠️  Could not determine current user for role permission check")
      fi
    fi
  fi

  # Test project-level permissions
  log_info "Checking project-level permissions..."

  # Check if we can enable services
  if timeout "$PERMISSION_CHECK_TIMEOUT" gcloud services list --project="$PROJECT_ID" --limit=1 &>/dev/null; then
    log_ok "✓ Can list/manage services"
  else
    EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 124 ]]; then
      PERMISSION_WARNINGS+=("⚠️  Timeout checking services (slow API response)")
    else
      PERMISSION_ERRORS+=("❌ Cannot manage services (required: serviceusage.services.enable)")
    fi
  fi

  # Check if we can manage service accounts
  if timeout "$PERMISSION_CHECK_TIMEOUT" gcloud iam service-accounts list --project="$PROJECT_ID" --limit=1 &>/dev/null; then
    log_ok "✓ Can manage service accounts"
  else
    EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 124 ]]; then
      PERMISSION_WARNINGS+=("⚠️  Timeout checking service accounts (slow API response)")
    else
      PERMISSION_ERRORS+=("❌ Cannot manage service accounts (required: iam.serviceAccounts.create)")
    fi
  fi

  # Check if we can manage secrets
  if timeout "$PERMISSION_CHECK_TIMEOUT" gcloud secrets list --project="$PROJECT_ID" --limit=1 &>/dev/null 2>&1; then
    log_ok "✓ Can manage secrets"
  else
    EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 124 ]]; then
      PERMISSION_WARNINGS+=("⚠️  Timeout checking secrets (slow API response)")
    else
      PERMISSION_WARNINGS+=("⚠️  Cannot list secrets - Secret Manager API may not be enabled yet (required: secretmanager.secrets.create)")
    fi
  fi

  # Check Infrastructure Manager permissions
  if timeout "$PERMISSION_CHECK_TIMEOUT" gcloud infra-manager previews list --project="$PROJECT_ID" --location="$REGION" --limit=1 &>/dev/null 2>&1; then
    log_ok "✓ Can manage Infrastructure Manager previews"
  else
    EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 124 ]]; then
      PERMISSION_WARNINGS+=("⚠️  Timeout checking Infrastructure Manager (slow API response)")
    else
      PERMISSION_WARNINGS+=("⚠️  Cannot list Infrastructure Manager previews - API may not be enabled yet (required: config.previews.create)")
    fi
  fi

  # Ensure current user has 'roles/orgpolicy.policyAdmin'
  # (required by Step 1 to disable 'iam.disableServiceAccountKeyCreation' if enforced)
  log_info "Checking 'roles/orgpolicy.policyAdmin'..."

  CURRENT_USER_FOR_POLICY=$(timeout 5 gcloud config get-value account 2>/dev/null || echo "unknown")
  if [[ "$CURRENT_USER_FOR_POLICY" != "unknown" ]]; then
    # Check at both org and project level
    HAS_POLICY_ADMIN_ORG=$(timeout "$PERMISSION_CHECK_TIMEOUT" gcloud organizations get-iam-policy "$ORGANIZATION_ID" \
      --flatten="bindings[].members" \
      --filter="bindings.members:user:$CURRENT_USER_FOR_POLICY AND bindings.role:roles/orgpolicy.policyAdmin" \
      --format="value(bindings.role)" 2>/dev/null || echo "")

    HAS_POLICY_ADMIN_PROJECT=$(timeout "$PERMISSION_CHECK_TIMEOUT" gcloud projects get-iam-policy "$PROJECT_ID" \
      --flatten="bindings[].members" \
      --filter="bindings.members:user:$CURRENT_USER_FOR_POLICY AND bindings.role:roles/orgpolicy.policyAdmin" \
      --format="value(bindings.role)" 2>/dev/null || echo "")

    if [[ -n "$HAS_POLICY_ADMIN_ORG" || -n "$HAS_POLICY_ADMIN_PROJECT" ]]; then
      log_ok "✓ User '$CURRENT_USER_FOR_POLICY' already has 'roles/orgpolicy.policyAdmin'."
    else
      log_warn "User '$CURRENT_USER_FOR_POLICY' is missing 'roles/orgpolicy.policyAdmin'."
      log_info "Attempting to grant 'roles/orgpolicy.policyAdmin' at organization level..."
      if gcloud organizations add-iam-policy-binding "$ORGANIZATION_ID" \
        --member="user:$CURRENT_USER_FOR_POLICY" \
        --role="roles/orgpolicy.policyAdmin" \
        --quiet >/dev/null; then
        log_ok "✓ Granted 'roles/orgpolicy.policyAdmin' to '$CURRENT_USER_FOR_POLICY' on organization '$ORGANIZATION_ID'."
      else
        PERMISSION_WARNINGS+=("⚠️  Could not grant 'roles/orgpolicy.policyAdmin' — if org policy 'iam.disableServiceAccountKeyCreation' is enforced, Step 1 may fail.")
      fi
    fi
  else
    PERMISSION_WARNINGS+=("⚠️  Could not determine current user for org policy permission check.")
  fi

  echo ""

  # Report errors and warnings
  if [[ ${#PERMISSION_ERRORS[@]} -gt 0 ]]; then
    log_error "Permission validation failed!"
    echo ""
    for error in "${PERMISSION_ERRORS[@]}"; do
      echo "  $error"
    done
    echo ""
    echo "Required permissions:"
    echo ""
    echo "Organization level (choose one):"
    echo "  • roles/owner (simplest - full access)"
    echo "  • roles/iam.organizationRoleAdmin + roles/resourcemanager.organizationAdmin"
    echo "    (BOTH roles required!)"
    echo ""
    echo "Important: roles/resourcemanager.organizationAdmin alone is NOT sufficient!"
    echo "  - It allows setting IAM policies but NOT creating custom roles"
    echo "  - You must also have roles/iam.organizationRoleAdmin"
    echo ""
    echo "Project level (choose one):"
    echo "  • roles/owner (simplest - full access)"
    echo "  • roles/editor (recommended)"
    echo "  • roles/serviceusage.serviceUsageAdmin + roles/iam.serviceAccountAdmin +"
    echo "    roles/secretmanager.admin + roles/config.admin (minimal)"
    echo ""
    echo "To grant the required organization permissions, run:"
    echo "  # Grant role creation permission"
    echo "  gcloud organizations add-iam-policy-binding $ORGANIZATION_ID \\"
    echo "    --member='user:YOUR_EMAIL' \\"
    echo "    --role='roles/iam.organizationRoleAdmin'"
    echo ""
    echo "  # Grant policy management permission"
    echo "  gcloud organizations add-iam-policy-binding $ORGANIZATION_ID \\"
    echo "    --member='user:YOUR_EMAIL' \\"
    echo "    --role='roles/resourcemanager.organizationAdmin'"
    echo ""
    echo "To grant project permissions, run:"
    echo "  gcloud projects add-iam-policy-binding $PROJECT_ID \\"
    echo "    --member='user:YOUR_EMAIL' \\"
    echo "    --role='roles/editor'"
    echo ""
    exit 1
  fi

  if [[ ${#PERMISSION_WARNINGS[@]} -gt 0 ]]; then
    log_warn "Permission validation warnings:"
    echo ""
    for warning in "${PERMISSION_WARNINGS[@]}"; do
      echo "  $warning"
    done
    echo ""
    echo "These warnings may be resolved automatically when APIs are enabled."
    echo "If the script fails, you may need additional permissions."
    echo ""
  fi

  log_ok "Permission validation passed!"
  echo ""
else
  log_warn "Skipping permission validation (--skip-permission-check enabled)"
  echo ""
fi

###############################################################################
# Confirmation prompt
###############################################################################
echo ""
log_info "StreamSecurity GCP Integration — Prerequisites Setup"
echo ""
echo "  Project ID       : $PROJECT_ID"
echo "  Organization ID  : $ORGANIZATION_ID"
echo "  Region           : $REGION"
echo "  StreamSec Host   : $STREAMSEC_HOST"
echo "  Workspace ID     : $WORKSPACE_ID"
echo "  API Token        : ${API_TOKEN:0:8}********"
echo "  Custom Role ID   : $CUSTOM_ROLE_ID"
echo "  Service Account  : $SA_NAME"
echo "  Secret Name      : $SECRET_NAME"
echo ""
echo "Infrastructure Manager:"
echo "  Deployment Name  : $DEPLOYMENT_NAME"
if [[ "$ORG_LEVEL_SINK" == true ]]; then
  echo "  Log Sink Mode    : Organization-level (single sink)"
else
  echo "  Log Sink Mode    : Project-level (per-project sinks)"
fi
echo "  Git Ref          : (auto-detect latest release tag)"
echo ""

if [[ "$AUTO_CONFIRM" != true ]]; then
  read -r -p "Proceed with the setup? [y/N] " response
  case "$response" in
    [yY][eE][sS]|[yY]) ;;
    *) log_warn "Aborted."; exit 1 ;;
  esac
fi

###############################################################################
# Step 1 — Enable required APIs
###############################################################################
TOTAL_STEPS=6

if [[ $START_FROM_STEP -le 1 ]]; then
  log_step "Step 1/$TOTAL_STEPS: Enabling required APIs and configuring project '$PROJECT_ID'..."

  REQUIRED_APIS=(
  "cloudbuild.googleapis.com"            # Cloud Build API (Infrastructure Manager dependency)
  "config.googleapis.com"                # Infrastructure Manager API
  "pubsub.googleapis.com"               # Pub/Sub API (for log collection topics)
  "cloudfunctions.googleapis.com"        # Cloud Functions API (for integration function)
  "secretmanager.googleapis.com"         # Secret Manager API (for credentials)
  "cloudasset.googleapis.com"            # Cloud Asset API (for asset inventory)
  "cloudresourcemanager.googleapis.com"  # Cloud Resource Manager API (for project/org management)
  "eventarc.googleapis.com"             # Eventarc API (for Cloud Functions v2 triggers)
  "iam.googleapis.com"                  # IAM API (for service account operations)
  "run.googleapis.com"                  # Cloud Run API (required by Cloud Functions v2)
  "logging.googleapis.com"              # Cloud Logging API (for log sinks)
  "storage.googleapis.com"              # Cloud Storage API (for Infrastructure Manager state)
  "artifactregistry.googleapis.com"     # Artifact Registry API (for Cloud Functions artifacts)
)

API_ENABLE_FAILED=0
for api in "${REQUIRED_APIS[@]}"; do
  log_info "Enabling $api ..."
  if ! gcloud services enable "$api" --project="$PROJECT_ID" --quiet 2>&1; then
    log_warn "Could not enable $api — it may already be enabled or require manual action."
    API_ENABLE_FAILED=1
  fi
done

  log_ok "API enablement completed."

  # Disable service account key creation constraint at project level (if enforced)
  log_info "Checking organization policy 'constraints/iam.disableServiceAccountKeyCreation'..."

  POLICY_ENFORCED=$(gcloud resource-manager org-policies describe \
    constraints/iam.disableServiceAccountKeyCreation \
    --effective \
    --project="$PROJECT_ID" \
    --format="value(booleanPolicy.enforced)" 2>/dev/null || echo "")

  if [[ "$POLICY_ENFORCED" == "True" ]]; then
    log_warn "Organization policy 'iam.disableServiceAccountKeyCreation' is enforced — disabling at project level..."
    if ! gcloud resource-manager org-policies disable-enforce \
      constraints/iam.disableServiceAccountKeyCreation \
      --project="$PROJECT_ID" \
      --quiet 2>&1; then
      log_error "Could not disable org policy. You may need 'orgpolicy.policy.set' permission or roles/orgpolicy.policyAdmin."
      API_ENABLE_FAILED=1
    else
      log_ok "✓ Organization policy disabled at project level."
    fi
  else
    log_ok "✓ Organization policy 'iam.disableServiceAccountKeyCreation' is not enforced."
  fi

  # Grant Cloud Build permissions to the default compute service account.
  # Cloud Functions v2 uses Cloud Build for builds, and the default compute SA
  # needs 'roles/cloudbuild.builds.builder' or the function deployment will fail with:
  #   "Could not build the function due to a missing permission on the build service account"
  log_info "Configuring Cloud Build service account permissions for Cloud Functions v2..."

  PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)" 2>/dev/null || echo "")
  if [[ -n "$PROJECT_NUMBER" ]]; then
    COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

    log_info "Granting 'roles/cloudbuild.builds.builder' to default compute SA ($COMPUTE_SA)..."
    if gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member="serviceAccount:$COMPUTE_SA" \
      --role="roles/cloudbuild.builds.builder" \
      --quiet >/dev/null 2>&1; then
      log_ok "✓ Granted 'roles/cloudbuild.builds.builder' to $COMPUTE_SA"
    else
      log_warn "Could not grant 'roles/cloudbuild.builds.builder' to $COMPUTE_SA"
      log_warn "You may need to grant this manually for Cloud Functions v2 to build successfully."
      API_ENABLE_FAILED=1
    fi

    log_info "Granting 'roles/cloudbuild.builds.builder' to Cloud Build SA (${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com)..."
    if gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
      --role="roles/cloudbuild.builds.builder" \
      --quiet >/dev/null 2>&1; then
      log_ok "✓ Granted 'roles/cloudbuild.builds.builder' to ${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
    else
      log_warn "Could not grant 'roles/cloudbuild.builds.builder' to Cloud Build SA — it may not exist yet."
    fi
  else
    log_warn "Could not determine project number — skipping Cloud Build SA configuration."
    log_warn "You may need to manually grant 'roles/cloudbuild.builds.builder' to the default compute SA."
    API_ENABLE_FAILED=1
  fi

  confirm_step "Enable required APIs and configure project" $API_ENABLE_FAILED
else
  log_info "Skipping Step 1: Enable required APIs"
fi

###############################################################################
# Step 2 — Create organization-level custom role
###############################################################################
if [[ $START_FROM_STEP -le 2 ]]; then
  log_step "Step 2/$TOTAL_STEPS: Creating organization-level custom role '$CUSTOM_ROLE_ID'..."

CUSTOM_ROLE_PERMISSIONS="\
bigquery.datasets.get,\
container.clusters.get,\
compute.instanceGroups.get,\
compute.instances.get,\
compute.snapshots.get,\
iam.serviceAccounts.actAs,\
iam.serviceAccounts.create,\
iam.serviceAccounts.get,\
iam.serviceAccounts.list,\
iam.serviceAccounts.update,\
iam.serviceAccounts.delete,\
iam.serviceAccounts.getIamPolicy,\
iam.serviceAccounts.setIamPolicy,\
iam.serviceAccountKeys.create,\
iam.serviceAccountKeys.delete,\
iam.serviceAccountKeys.get,\
iam.serviceAccountKeys.list,\
resourcemanager.organizations.get,\
resourcemanager.organizations.getIamPolicy,\
resourcemanager.organizations.setIamPolicy,\
resourcemanager.projects.get,\
resourcemanager.projects.list,\
resourcemanager.projects.getIamPolicy,\
resourcemanager.projects.setIamPolicy,\
pubsub.topics.create,\
pubsub.topics.get,\
pubsub.topics.list,\
pubsub.topics.update,\
pubsub.topics.delete,\
pubsub.topics.getIamPolicy,\
pubsub.topics.setIamPolicy,\
pubsub.topics.publish,\
pubsub.topics.attachSubscription,\
logging.sinks.create,\
logging.sinks.get,\
logging.sinks.list,\
logging.sinks.update,\
logging.sinks.delete,\
logging.logs.list,\
logging.logEntries.list,\
secretmanager.secrets.create,\
secretmanager.secrets.get,\
secretmanager.secrets.delete,\
secretmanager.secrets.update,\
secretmanager.secrets.getIamPolicy,\
secretmanager.secrets.setIamPolicy,\
secretmanager.versions.access,\
secretmanager.versions.add,\
secretmanager.versions.destroy,\
secretmanager.versions.enable,\
secretmanager.versions.get,\
cloudfunctions.functions.create,\
cloudfunctions.functions.get,\
cloudfunctions.functions.list,\
cloudfunctions.functions.update,\
cloudfunctions.functions.delete,\
cloudfunctions.functions.getIamPolicy,\
cloudfunctions.functions.setIamPolicy,\
cloudfunctions.functions.invoke,\
cloudfunctions.operations.get,\
cloudasset.assets.searchAllResources"

# Check if the role already exists; if so, compare permissions and update if needed.
ROLE_EXIT_CODE=0
if gcloud iam roles describe "$CUSTOM_ROLE_ID" \
      --organization="$ORGANIZATION_ID" &>/dev/null; then

  # Fetch existing permissions (one per line, sorted)
  EXISTING_PERMS=$(gcloud iam roles describe "$CUSTOM_ROLE_ID" \
    --organization="$ORGANIZATION_ID" \
    --format="value(includedPermissions)" 2>/dev/null \
    | tr ';' '\n' | sort)

  # Build desired permissions list (sorted) from the comma-separated string
  DESIRED_PERMS=$(echo "$CUSTOM_ROLE_PERMISSIONS" | tr ',' '\n' | sort)

  if [[ "$EXISTING_PERMS" == "$DESIRED_PERMS" ]]; then
    log_ok "Custom role '$CUSTOM_ROLE_ID' already exists with the correct permissions — no update needed."
  else
    log_warn "Custom role '$CUSTOM_ROLE_ID' already exists but has different permissions."

    # Show the diff
    ADDED=$(comm -13 <(echo "$EXISTING_PERMS") <(echo "$DESIRED_PERMS"))
    REMOVED=$(comm -23 <(echo "$EXISTING_PERMS") <(echo "$DESIRED_PERMS"))

    if [[ -n "$ADDED" ]]; then
      echo ""
      log_info "Permissions to ADD:"
      echo "$ADDED" | while read -r perm; do echo "    + $perm"; done
    fi
    if [[ -n "$REMOVED" ]]; then
      echo ""
      log_warn "Permissions to REMOVE:"
      echo "$REMOVED" | while read -r perm; do echo "    - $perm"; done
    fi
    echo ""

    UPDATE_ROLE=false
    if [[ "$AUTO_CONFIRM" == true ]]; then
      UPDATE_ROLE=true
    else
      read -r -p "Do you want to overwrite the existing role permissions? [y/N] " response
      case "$response" in
        [yY][eE][sS]|[yY]) UPDATE_ROLE=true ;;
        *) log_warn "Keeping existing role permissions." ;;
      esac
    fi

    if [[ "$UPDATE_ROLE" == true ]]; then
      log_info "Updating custom role permissions..."
      gcloud iam roles update "$CUSTOM_ROLE_ID" \
        --organization="$ORGANIZATION_ID" \
        --permissions="$CUSTOM_ROLE_PERMISSIONS" \
        --stage="GA" \
        --quiet || ROLE_EXIT_CODE=$?
    fi
  fi
else
  gcloud iam roles create "$CUSTOM_ROLE_ID" \
    --organization="$ORGANIZATION_ID" \
    --title="$CUSTOM_ROLE_TITLE" \
    --description="This role is used for stream-security infrastructure manager deployment" \
    --stage="GA" \
    --permissions="$CUSTOM_ROLE_PERMISSIONS" \
    --quiet || ROLE_EXIT_CODE=$?
fi

  log_ok "Custom role 'organizations/$ORGANIZATION_ID/roles/$CUSTOM_ROLE_ID' is ready."
  confirm_step "Create/update custom IAM role" $ROLE_EXIT_CODE
else
  log_info "Skipping Step 2: Create organization-level custom role"
fi

###############################################################################
# Step 3 — Create the service account
###############################################################################
if [[ $START_FROM_STEP -le 3 ]]; then
  log_step "Step 3/$TOTAL_STEPS: Creating service account '$SA_NAME' in project '$PROJECT_ID'..."

SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

SA_EXIT_CODE=0
if gcloud iam service-accounts describe "$SA_EMAIL" \
      --project="$PROJECT_ID" &>/dev/null; then
  log_warn "Service account '$SA_EMAIL' already exists — skipping creation."
else
  gcloud iam service-accounts create "$SA_NAME" \
    --project="$PROJECT_ID" \
    --display-name="$SA_DISPLAY_NAME" \
    --description="This service account is used for stream-security infrastructure manager deployment" \
    --quiet || SA_EXIT_CODE=$?
  log_ok "Service account '$SA_EMAIL' created."
fi

  confirm_step "Create service account" $SA_EXIT_CODE
else
  log_info "Skipping Step 3: Create service account"
  # Still need to set SA_EMAIL for later steps
  SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
fi

###############################################################################
# Step 4 — Grant IAM roles at the organization level
###############################################################################
if [[ $START_FROM_STEP -le 4 ]]; then
  log_step "Step 4/$TOTAL_STEPS: Granting organization-level IAM roles to '$SA_EMAIL'..."

# 4a. Grant the custom role
log_info "Granting custom role 'organizations/$ORGANIZATION_ID/roles/$CUSTOM_ROLE_ID'..."
IAM_EXIT_CODE=0
gcloud organizations add-iam-policy-binding "$ORGANIZATION_ID" \
  --member="serviceAccount:$SA_EMAIL" \
  --role="organizations/$ORGANIZATION_ID/roles/$CUSTOM_ROLE_ID" \
  --quiet >/dev/null || IAM_EXIT_CODE=$?

# 4b. Grant Cloud Infrastructure Manager Agent role
log_info "Granting 'roles/config.agent' (Cloud Infrastructure Manager Agent)..."
gcloud organizations add-iam-policy-binding "$ORGANIZATION_ID" \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/config.agent" \
  --quiet >/dev/null || IAM_EXIT_CODE=$?

  log_ok "IAM bindings configured successfully."
  confirm_step "Grant IAM roles at organization level" $IAM_EXIT_CODE
else
  log_info "Skipping Step 4: Grant IAM roles at organization level"
fi

###############################################################################
# Step 5 — Create the credentials secret in Secret Manager
###############################################################################
if [[ $START_FROM_STEP -le 5 ]]; then
  log_step "Step 5/$TOTAL_STEPS: Creating Secret Manager secret '$SECRET_NAME' in project '$PROJECT_ID'..."

SECRET_VALUE=$(cat <<JSONEOF
{
  "host": "${STREAMSEC_HOST}",
  "workspace_id": "${WORKSPACE_ID}",
  "api_token": "${API_TOKEN}"
}
JSONEOF
)

SECRET_EXIT_CODE=0
if gcloud secrets describe "$SECRET_NAME" \
      --project="$PROJECT_ID" &>/dev/null; then
  log_warn "Secret '$SECRET_NAME' already exists in project '$PROJECT_ID' — skipping creation."
  log_warn "If you need to update the secret, delete it manually and re-run this script."
else
  echo -n "$SECRET_VALUE" | gcloud secrets create "$SECRET_NAME" \
    --project="$PROJECT_ID" \
    --data-file=- \
    --replication-policy="automatic" \
    --quiet || SECRET_EXIT_CODE=$?
fi

  log_ok "Secret '$SECRET_NAME' is ready."
  confirm_step "Create Secret Manager secret" $SECRET_EXIT_CODE
else
  log_info "Skipping Step 5: Create Secret Manager secret"
fi

###############################################################################
# Step 6 — Create Infrastructure Manager Preview
###############################################################################
if [[ $START_FROM_STEP -le 6 ]]; then
  log_step "Step 6/$TOTAL_STEPS: Creating Infrastructure Manager preview deployment..."

  # Determine Git ref (latest release tag)
  log_info "Determining latest release tag from GitHub..."
  GIT_REF=$(curl -s "https://api.github.com/repos/streamsec-terraform/terraform-streamsec-google-integration/releases/latest" \
    | grep '"tag_name":' \
    | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')

  if [[ -z "$GIT_REF" ]]; then
    log_warn "Could not determine latest release tag. Falling back to 'main' branch."
    GIT_REF="main"
  else
    log_ok "Using latest release tag: $GIT_REF"
  fi

  PREVIEW_NAME="${DEPLOYMENT_NAME}-preview-$(date +%s)"

  log_info "Preview name: $PREVIEW_NAME"
  log_info "Git ref: $GIT_REF"

  # Create the preview deployment
  log_info "Creating preview (this may take several minutes)..."

  PREVIEW_CREATE_EXIT_CODE=0
  # Infrastructure Manager requires the full service account resource path
  SA_RESOURCE_PATH="projects/$PROJECT_ID/serviceAccounts/$SA_EMAIL"

  gcloud infra-manager previews create "$PREVIEW_NAME" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --service-account="$SA_RESOURCE_PATH" \
    --git-source-repo="$GIT_REPO" \
    --git-source-directory="$GIT_DIRECTORY" \
    --git-source-ref="$GIT_REF" \
    --input-values="google_project_id=$PROJECT_ID,google_region=$REGION,org_id=$ORGANIZATION_ID,streamsec_secret_name=$SECRET_NAME,org_level_sink=$ORG_LEVEL_SINK" \
    --labels="managed-by=setup-script" \
    --async \
    --quiet || PREVIEW_CREATE_EXIT_CODE=$?

  log_info "Preview creation initiated: $PREVIEW_NAME"
  confirm_step "Create Infrastructure Manager preview" $PREVIEW_CREATE_EXIT_CODE

  # If preview creation failed, skip the monitoring step
  if [[ $PREVIEW_CREATE_EXIT_CODE -ne 0 ]]; then
    log_error "Preview creation failed. Skipping monitoring step."
    echo ""
    echo "You can try creating the preview manually in the GCP Console:"
    echo "  https://console.cloud.google.com/infra-manager/deployments?project=$PROJECT_ID"
    echo ""
    exit 1
  fi

  # Wait for preview to complete
  log_info "Waiting for preview to complete..."
  echo ""

  MAX_WAIT_TIME=600  # 10 minutes
  ELAPSED=0
  POLL_INTERVAL=10

  while [[ $ELAPSED -lt $MAX_WAIT_TIME ]]; do
    PREVIEW_STATE=$(gcloud infra-manager previews describe "$PREVIEW_NAME" \
      --project="$PROJECT_ID" \
      --location="$REGION" \
      --format="value(state)" 2>/dev/null || echo "UNKNOWN")

    case "$PREVIEW_STATE" in
      SUCCEEDED)
        echo ""
        log_ok "Preview completed successfully!"

        # Get preview details
        log_info "Fetching preview results..."
        PREVIEW_ARTIFACTS=$(gcloud infra-manager previews describe "$PREVIEW_NAME" \
          --project="$PROJECT_ID" \
          --location="$REGION" \
          --format="value(previewArtifacts)" 2>/dev/null)

        echo ""
        echo "============================================================"
        log_info "Infrastructure Manager Preview Results"
        echo "============================================================"
        echo ""
        echo "  Preview Name    : $PREVIEW_NAME"
        echo "  State           : $PREVIEW_STATE"
        echo "  Service Account : $SA_EMAIL"
        echo "  Git Repository  : $GIT_REPO"
        echo "  Git Directory   : $GIT_DIRECTORY"
        echo "  Git Ref         : $GIT_REF"
        echo ""

        if [[ -n "$PREVIEW_ARTIFACTS" ]]; then
          log_info "Preview artifacts location: $PREVIEW_ARTIFACTS"
          echo ""
          log_info "You can view the Terraform plan by running:"
          echo "  gcloud infra-manager previews export $PREVIEW_NAME --location=$REGION --project=$PROJECT_ID"
          echo ""
        fi

        echo "Next steps:"
        echo "  1. Review the preview results in the GCP Console:"
        echo "     https://console.cloud.google.com/infra-manager/previews/details/$REGION/$PREVIEW_NAME?project=$PROJECT_ID"
        echo ""
        echo "  2. If the preview looks correct, create the deployment:"
        echo "     https://console.cloud.google.com/infra-manager/deployments?project=$PROJECT_ID"
        echo "     - Use the same configuration as the preview"
        echo "     - OR run the following command:"
        echo ""
        echo "     gcloud infra-manager deployments apply $DEPLOYMENT_NAME \\"
        echo "       --project=$PROJECT_ID \\"
        echo "       --location=$REGION \\"
        echo "       --service-account=$SA_EMAIL \\"
        echo "       --git-source-repo=$GIT_REPO \\"
        echo "       --git-source-directory=$GIT_DIRECTORY \\"
        echo "       --git-source-ref=$GIT_REF \\"
        echo "       --input-values='google_project_id=$PROJECT_ID,google_region=$REGION,org_id=$ORGANIZATION_ID,streamsec_secret_name=$SECRET_NAME,org_level_sink=$ORG_LEVEL_SINK'"
        echo ""

        break
        ;;
      FAILED)
        echo ""
        log_error "Preview failed!"

        # Try to get error details
        ERROR_LOGS=$(gcloud infra-manager previews describe "$PREVIEW_NAME" \
          --project="$PROJECT_ID" \
          --location="$REGION" \
          --format="value(errorLogs)" 2>/dev/null)

        if [[ -n "$ERROR_LOGS" ]]; then
          echo ""
          log_error "Error details: $ERROR_LOGS"
        fi

        echo ""
        echo "You can view detailed error information in the GCP Console:"
        echo "  https://console.cloud.google.com/infra-manager/previews/details/$REGION/$PREVIEW_NAME?project=$PROJECT_ID"
        echo ""
        echo "Common issues:"
        echo "  - Check that all APIs are enabled"
        echo "  - Verify service account has correct permissions"
        echo "  - Review the error logs for specific Terraform errors"
        echo ""

        exit 1
        ;;
      CREATING|APPLYING)
        echo -ne "\r  Preview state: $PREVIEW_STATE... (${ELAPSED}s elapsed)"
        ;;
      *)
        echo -ne "\r  Preview state: $PREVIEW_STATE... (${ELAPSED}s elapsed)"
        ;;
    esac

    sleep $POLL_INTERVAL
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
  done

  if [[ $ELAPSED -ge $MAX_WAIT_TIME ]]; then
    echo ""
    log_warn "Preview is taking longer than expected."
    echo ""
    echo "You can check the status in the GCP Console:"
    echo "  https://console.cloud.google.com/infra-manager/previews/details/$REGION/$PREVIEW_NAME?project=$PROJECT_ID"
    echo ""
    echo "Or run: gcloud infra-manager previews describe $PREVIEW_NAME --location=$REGION --project=$PROJECT_ID"
    echo ""
  fi

    echo ""
  else
    log_info "Skipping Step 6: Create Infrastructure Manager preview"
fi
