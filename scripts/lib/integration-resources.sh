#!/usr/bin/env bash
#
# The resources the base integration module creates under fixed names: how to
# find, delete and recognise each one in an Infrastructure Manager revision.
# The GKE module's names are a prefix plus a random suffix (kind "gke-*=<name>").
# Sourced by setup-prerequisites.sh and cleanup-abandoned-deployment.sh, which
# set PROJECT_ID, REGION and ORGANIZATION_ID. "ir_" = integration resource.

# The module's default names; the environment can override each one.
SA_ACCOUNT_ID="${SA_ACCOUNT_ID:-stream-security}"
FUNCTION_SA_ACCOUNT_ID="${FUNCTION_SA_ACCOUNT_ID:-stream-security-function-sa}"
FUNCTION_NAME="${FUNCTION_NAME:-stream-security-events-function}"
PUBSUB_TOPIC="${PUBSUB_TOPIC:-stream-security-events-topic}"
LOGGING_SINK="${LOGGING_SINK:-stream-security-events-sink}"
REGIONAL_SECRET="${REGIONAL_SECRET:-stream-security}"
GLOBAL_SECRET="${GLOBAL_SECRET:-stream-security-collection-token}"
# The GKE audit logs module (enable_gke_logs): name prefixes, the module adds -<8 hex>.
GKE_FUNCTION_NAME="${GKE_FUNCTION_NAME:-stream-sec-gke-logs-pubsub}"
GKE_SINK="${GKE_SINK:-streamsec-gke-audit-logs-pubsub}"
GKE_TOPIC="${GKE_TOPIC:-streamsec-gke-audit-logs}"
GKE_SECRET="${GKE_SECRET:-streamsec-gke-logs-token}"
GKE_SA_ACCOUNT_ID="${GKE_SA_ACCOUNT_ID:-streamsec-gke-audit}"

# In deletion order: functions before the topic and service account they use,
# sinks before the topic they write to.
IR_KINDS=(events-function gke-function org-sink project-sink gke-org-sink gke-project-sink
  topic gke-topic global-secret gke-secret regional-secret function-sa gke-sa sa)

ir_is_kind() { [[ " ${IR_KINDS[*]} " == *" $1 "* ]]; }

ir_sa_email() { echo "$1@${PROJECT_ID}.iam.gserviceaccount.com"; }

# Runs ir_* function $1 for "<GKE kind>=<name>" $2 as the matching base kind with that name.
ir_gke() {
  local base="${2%%=*}" name="${2#*=}"
  base="${base#gke-}"
  case "$base" in
    function) base=events-function ;;
    secret)   base=global-secret ;;
    sa)       base=function-sa ;;
  esac
  FUNCTION_NAME="$name" LOGGING_SINK="$name" PUBSUB_TOPIC="$name" \
    GLOBAL_SECRET="$name" FUNCTION_SA_ACCOUNT_ID="$name" "$1" "$base"
}

ir_gke_prefix() {
  case "$1" in
    gke-function) echo "$GKE_FUNCTION_NAME" ;;
    gke-*-sink)   echo "$GKE_SINK" ;;
    gke-topic)    echo "$GKE_TOPIC" ;;
    gke-secret)   echo "$GKE_SECRET" ;;
    gke-sa)       echo "$GKE_SA_ACCOUNT_ID" ;;
  esac
}

# The names of GKE kind $1 that are "<prefix>-<8 hex>", one per line (there may be several).
# 0 = some, 1 = none (or the API is off), 2 = couldn't tell (the error goes to stderr).
ir_gke_list() {
  local out
  case "$1" in
    gke-function)     out=$(gcloud functions list --regions="$REGION" --project="$PROJECT_ID" --format='value(name.basename())' 2>&1) ;;
    gke-org-sink)     out=$(gcloud logging sinks list --organization="$ORGANIZATION_ID" --format='value(name)' 2>&1) ;;
    gke-project-sink) out=$(gcloud logging sinks list --project="$PROJECT_ID" --format='value(name)' 2>&1) ;;
    gke-topic)        out=$(gcloud pubsub topics list --project="$PROJECT_ID" --format='value(name.basename())' 2>&1) ;;
    gke-secret)       out=$(gcloud secrets list --project="$PROJECT_ID" --format='value(name.basename())' 2>&1) ;;
    gke-sa)           out=$(gcloud iam service-accounts list --project="$PROJECT_ID" --format='value(email)' 2>&1) && out=$(sed 's/@.*//' <<<"$out") ;;
  esac || {
    case "$out" in
      *SERVICE_DISABLED* | *"has not been used"*) return 1 ;;
    esac
    echo "$out" >&2
    return 2
  }
  grep -E "^$(ir_gke_prefix "$1")-[0-9a-f]{8}\$" <<<"$out"
}

# Regional secrets are served only by the regional endpoint, and gcloud doesn't
# switch to it for --location (it fails with INVALID_ARGUMENT).
ir_regional_secrets() {
  CLOUDSDK_API_ENDPOINT_OVERRIDES_SECRETMANAGER="https://secretmanager.${REGION}.rep.googleapis.com/" \
    gcloud secrets "$@" --location="$REGION" --project="$PROJECT_ID"
}

ir_label() {
  if [[ "$1" == gke-* ]]; then echo "GKE $(ir_gke ir_label "$1")"; return; fi
  case "$1" in
    events-function)   echo "Cloud Function v2: $FUNCTION_NAME ($REGION)" ;;
    org-sink)          echo "Org logging sink: $LOGGING_SINK" ;;
    project-sink)      echo "Project logging sink: $LOGGING_SINK" ;;
    topic)             echo "Pub/Sub topic: $PUBSUB_TOPIC" ;;
    global-secret)     echo "Global secret: $GLOBAL_SECRET" ;;
    regional-secret)   echo "Regional secret: $REGIONAL_SECRET ($REGION)" ;;
    function-sa)       echo "Function service account: $(ir_sa_email "$FUNCTION_SA_ACCOUNT_ID")" ;;
    sa)                echo "Service account: $(ir_sa_email "$SA_ACCOUNT_ID")" ;;
  esac
}

ir_describe() {
  case "$1" in
    events-function)   gcloud functions describe "$FUNCTION_NAME" --region="$REGION" --project="$PROJECT_ID" --gen2 ;;
    org-sink)          gcloud logging sinks describe "$LOGGING_SINK" --organization="$ORGANIZATION_ID" ;;
    project-sink)      gcloud logging sinks describe "$LOGGING_SINK" --project="$PROJECT_ID" ;;
    topic)             gcloud pubsub topics describe "$PUBSUB_TOPIC" --project="$PROJECT_ID" ;;
    global-secret)     gcloud secrets describe "$GLOBAL_SECRET" --project="$PROJECT_ID" ;;
    regional-secret)   ir_regional_secrets describe "$REGIONAL_SECRET" ;;
    function-sa)       gcloud iam service-accounts describe "$(ir_sa_email "$FUNCTION_SA_ACCOUNT_ID")" --project="$PROJECT_ID" ;;
    sa)                gcloud iam service-accounts describe "$(ir_sa_email "$SA_ACCOUNT_ID")" --project="$PROJECT_ID" ;;
  esac
}

# 0 = exists, 1 = doesn't (or its API is off), 2 = couldn't tell (the error goes to stderr).
ir_exists() {
  local err
  err=$(ir_describe "$1" 2>&1 >/dev/null) && return 0
  case "$err" in
    *NOT_FOUND* | *"not found"* | *"does not exist"* | *"status=[404]"* | *SERVICE_DISABLED* | *"has not been used"*) return 1 ;;
  esac
  echo "$err" >&2
  return 2
}

ir_delete() {
  if [[ "$1" == gke-* ]]; then ir_gke ir_delete "$1"; return; fi
  case "$1" in
    events-function)   gcloud functions delete "$FUNCTION_NAME" --region="$REGION" --project="$PROJECT_ID" --gen2 --quiet ;;
    org-sink)          gcloud logging sinks delete "$LOGGING_SINK" --organization="$ORGANIZATION_ID" --quiet ;;
    project-sink)      gcloud logging sinks delete "$LOGGING_SINK" --project="$PROJECT_ID" --quiet ;;
    # IAM bindings on the topic go with it.
    topic)             gcloud pubsub topics delete "$PUBSUB_TOPIC" --project="$PROJECT_ID" --quiet ;;
    global-secret)     gcloud secrets delete "$GLOBAL_SECRET" --project="$PROJECT_ID" --quiet ;;
    regional-secret)   ir_regional_secrets delete "$REGIONAL_SECRET" --quiet ;;
    function-sa)       gcloud iam service-accounts delete "$(ir_sa_email "$FUNCTION_SA_ACCOUNT_ID")" --project="$PROJECT_ID" --quiet ;;
    # Its keys go with it.
    sa)                gcloud iam service-accounts delete "$(ir_sa_email "$SA_ACCOUNT_ID")" --project="$PROJECT_ID" --quiet ;;
  esac
}

# "<terraform type>\t<id>" of the resource in `gcloud infra-manager resources list`. @P@ is
# the project ID or number; a leading * matches any prefix (an org sink's name is unique in the org).
ir_state_match() {
  case "$1" in
    events-function)   printf 'google_cloudfunctions2_function\tprojects/@P@/locations/%s/functions/%s\n' "$REGION" "$FUNCTION_NAME" ;;
    org-sink)          printf 'google_logging_organization_sink\t*/sinks/%s\n' "$LOGGING_SINK" ;;
    project-sink)      printf 'google_logging_project_sink\tprojects/@P@/sinks/%s\n' "$LOGGING_SINK" ;;
    topic)             printf 'google_pubsub_topic\tprojects/@P@/topics/%s\n' "$PUBSUB_TOPIC" ;;
    global-secret)     printf 'google_secret_manager_secret\tprojects/@P@/secrets/%s\n' "$GLOBAL_SECRET" ;;
    regional-secret)   printf 'google_secret_manager_regional_secret\tprojects/@P@/locations/%s/secrets/%s\n' "$REGION" "$REGIONAL_SECRET" ;;
    function-sa)       printf 'google_service_account\tprojects/@P@/serviceAccounts/%s\n' "$(ir_sa_email "$FUNCTION_SA_ACCOUNT_ID")" ;;
    sa)                printf 'google_service_account\tprojects/@P@/serviceAccounts/%s\n' "$(ir_sa_email "$SA_ACCOUNT_ID")" ;;
  esac
}

# Number of output lines of a command, or '?' when it fails.
ir_count() {
  local out
  out=$("$@" 2>/dev/null) || { echo '?'; return 0; }
  grep -c . <<<"$out" || true
}

# What uses the resource, to judge whether deleting it is safe.
ir_hints() {
  local value email
  case "$1" in
    events-function)
      value=$(gcloud functions describe "$FUNCTION_NAME" --region="$REGION" --project="$PROJECT_ID" --gen2 \
        --format='value(eventTrigger.pubsubTopic)' 2>/dev/null) || value='?'
      echo "trigger: ${value:--}" ;;
    org-sink | project-sink)
      value=$(ir_sink_destination "$1") || value='?'
      echo "destination: ${value:--}" ;;
    topic)
      echo "$(ir_count gcloud pubsub topics list-subscriptions "$PUBSUB_TOPIC" --project="$PROJECT_ID" --format='value(.)') subscriptions," \
        "$(ir_count gcloud pubsub topics get-iam-policy "$PUBSUB_TOPIC" --project="$PROJECT_ID" \
          --flatten='bindings[].members' --format='value(bindings.role)') IAM bindings" ;;
    global-secret)
      echo "$(ir_count gcloud secrets get-iam-policy "$GLOBAL_SECRET" --project="$PROJECT_ID" \
        --flatten='bindings[].members' --format='value(bindings.role)') IAM bindings" ;;
    regional-secret)
      echo "$(ir_count ir_regional_secrets get-iam-policy "$REGIONAL_SECRET" \
        --flatten='bindings[].members' --format='value(bindings.role)') IAM bindings" ;;
    function-sa | sa)
      email=$(ir_sa_email "$FUNCTION_SA_ACCOUNT_ID")
      [[ "$1" == sa ]] && email=$(ir_sa_email "$SA_ACCOUNT_ID")
      value="$(ir_count gcloud iam service-accounts keys list --iam-account="$email" --managed-by=user \
          --project="$PROJECT_ID" --format='value(name)') user-managed keys,"
      value+=" $(ir_count gcloud projects get-iam-policy "$PROJECT_ID" --flatten='bindings[].members' \
          --filter="bindings.members:serviceAccount:$email" --format='value(bindings.role)') project roles"
      if [[ "$1" == sa && -n "$ORGANIZATION_ID" ]]; then
        value+=", $(ir_count gcloud organizations get-iam-policy "$ORGANIZATION_ID" --flatten='bindings[].members' \
          --filter="bindings.members:serviceAccount:$email" --format='value(bindings.role)') org roles"
      fi
      echo "$value" ;;
  esac
}

# Why the resource looks in use (subscriptions, keys, accessors), or nothing.
ir_in_use() {
  local n
  case "$1" in
    topic)
      n=$(ir_count gcloud pubsub topics list-subscriptions "$PUBSUB_TOPIC" --project="$PROJECT_ID" --format='value(.)')
      [[ "$n" == 0 ]] || echo "subscriptions: $n" ;;
    function-sa | sa)
      if [[ "$1" == sa ]]; then
        n=$(ir_count gcloud iam service-accounts keys list --iam-account="$(ir_sa_email "$SA_ACCOUNT_ID")" \
          --managed-by=user --project="$PROJECT_ID" --format='value(name)')
      else
        n=$(ir_count gcloud iam service-accounts keys list --iam-account="$(ir_sa_email "$FUNCTION_SA_ACCOUNT_ID")" \
          --managed-by=user --project="$PROJECT_ID" --format='value(name)')
      fi
      [[ "$n" == 0 ]] || echo "user-managed keys: $n" ;;
    regional-secret)
      n=$(ir_count ir_regional_secrets get-iam-policy "$REGIONAL_SECRET" \
        --flatten='bindings[].members' --format='value(bindings.role)')
      [[ "$n" == 0 ]] || echo "IAM bindings: $n" ;;
  esac
  return 0
}

# The cleanup-abandoned-deployment.sh flag that names the resource (not for GKE kinds).
ir_name_flag() {
  case "$1" in
    events-function)        echo "--function-name $FUNCTION_NAME" ;;
    org-sink | project-sink) echo "--logging-sink $LOGGING_SINK" ;;
    topic)                  echo "--pubsub-topic $PUBSUB_TOPIC" ;;
    global-secret)          echo "--global-secret $GLOBAL_SECRET" ;;
    regional-secret)        echo "--regional-secret $REGIONAL_SECRET" ;;
    function-sa)            echo "--function-sa-id $FUNCTION_SA_ACCOUNT_ID" ;;
    sa)                     echo "--sa-account-id $SA_ACCOUNT_ID" ;;
  esac
}

ir_sink_destination() {
  if [[ "$1" == org-sink ]]; then
    gcloud logging sinks describe "$LOGGING_SINK" --organization="$ORGANIZATION_ID" --format='value(destination)'
  else
    gcloud logging sinks describe "$LOGGING_SINK" --project="$PROJECT_ID" --format='value(destination)'
  fi 2>/dev/null
}
