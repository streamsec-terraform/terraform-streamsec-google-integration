#!/usr/bin/env bash
#
# The resources the base integration module creates under fixed names: how to
# find, delete and recognise each one in an Infrastructure Manager revision.
# Sourced by setup-prerequisites.sh and cleanup-abandoned-deployment.sh, which
# set PROJECT_ID, REGION and ORGANIZATION_ID. "ir_" = integration resource.

# The module's default names; the environment can override each one.
SA_ACCOUNT_ID="${SA_ACCOUNT_ID:-stream-security}"
FUNCTION_SA_ACCOUNT_ID="${FUNCTION_SA_ACCOUNT_ID:-stream-security-function-sa}"
FUNCTION_NAME="${FUNCTION_NAME:-stream-security-events-function}"
FLOWLOGS_FUNCTION_NAME="${FLOWLOGS_FUNCTION_NAME:-stream-security-flowlogs-function}"
PUBSUB_TOPIC="${PUBSUB_TOPIC:-stream-security-events-topic}"
LOGGING_SINK="${LOGGING_SINK:-stream-security-events-sink}"
REGIONAL_SECRET="${REGIONAL_SECRET:-stream-security}"
GLOBAL_SECRET="${GLOBAL_SECRET:-stream-security-collection-token}"

# In deletion order: functions before the topic and service account they use,
# sinks before the topic they write to.
IR_KINDS=(events-function flowlogs-function org-sink project-sink topic global-secret regional-secret function-sa sa)

ir_is_kind() { [[ " ${IR_KINDS[*]} " == *" $1 "* ]]; }

ir_sa_email() { echo "$1@${PROJECT_ID}.iam.gserviceaccount.com"; }

# Regional secrets are served only by the regional endpoint, and gcloud doesn't
# switch to it for --location (it fails with INVALID_ARGUMENT).
ir_regional_secrets() {
  CLOUDSDK_API_ENDPOINT_OVERRIDES_SECRETMANAGER="https://secretmanager.${REGION}.rep.googleapis.com/" \
    gcloud secrets "$@" --location="$REGION" --project="$PROJECT_ID"
}

ir_label() {
  case "$1" in
    events-function)   echo "Cloud Function v2: $FUNCTION_NAME ($REGION)" ;;
    flowlogs-function) echo "Cloud Function (1st gen): $FLOWLOGS_FUNCTION_NAME ($REGION)" ;;
    org-sink)          echo "Org logging sink: $LOGGING_SINK" ;;
    project-sink)      echo "Project logging sink: $LOGGING_SINK" ;;
    topic)             echo "Pub/Sub topic: $PUBSUB_TOPIC" ;;
    global-secret)     echo "Global secret: $GLOBAL_SECRET" ;;
    regional-secret)   echo "Regional secret: $REGIONAL_SECRET ($REGION)" ;;
    function-sa)       echo "Function service account: $(ir_sa_email "$FUNCTION_SA_ACCOUNT_ID")" ;;
    sa)                echo "Service account: $(ir_sa_email "$SA_ACCOUNT_ID")" ;;
  esac
}

ir_exists() {
  case "$1" in
    events-function)   gcloud functions describe "$FUNCTION_NAME" --region="$REGION" --project="$PROJECT_ID" --gen2 ;;
    flowlogs-function) gcloud functions describe "$FLOWLOGS_FUNCTION_NAME" --region="$REGION" --project="$PROJECT_ID" --no-gen2 ;;
    org-sink)          gcloud logging sinks describe "$LOGGING_SINK" --organization="$ORGANIZATION_ID" ;;
    project-sink)      gcloud logging sinks describe "$LOGGING_SINK" --project="$PROJECT_ID" ;;
    topic)             gcloud pubsub topics describe "$PUBSUB_TOPIC" --project="$PROJECT_ID" ;;
    global-secret)     gcloud secrets describe "$GLOBAL_SECRET" --project="$PROJECT_ID" ;;
    regional-secret)   ir_regional_secrets describe "$REGIONAL_SECRET" ;;
    function-sa)       gcloud iam service-accounts describe "$(ir_sa_email "$FUNCTION_SA_ACCOUNT_ID")" --project="$PROJECT_ID" ;;
    sa)                gcloud iam service-accounts describe "$(ir_sa_email "$SA_ACCOUNT_ID")" --project="$PROJECT_ID" ;;
  esac &>/dev/null
}

ir_delete() {
  case "$1" in
    events-function)   gcloud functions delete "$FUNCTION_NAME" --region="$REGION" --project="$PROJECT_ID" --gen2 --quiet ;;
    flowlogs-function) gcloud functions delete "$FLOWLOGS_FUNCTION_NAME" --region="$REGION" --project="$PROJECT_ID" --no-gen2 --quiet ;;
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

# "<terraform type>\t<id>", as `gcloud infra-manager resources list` shows the resource.
ir_state_id() {
  case "$1" in
    events-function)   printf 'google_cloudfunctions2_function\tprojects/%s/locations/%s/functions/%s\n' "$PROJECT_ID" "$REGION" "$FUNCTION_NAME" ;;
    flowlogs-function) printf 'google_cloudfunctions_function\tprojects/%s/locations/%s/functions/%s\n' "$PROJECT_ID" "$REGION" "$FLOWLOGS_FUNCTION_NAME" ;;
    org-sink)          printf 'google_logging_organization_sink\torganizations/%s/sinks/%s\n' "$ORGANIZATION_ID" "$LOGGING_SINK" ;;
    project-sink)      printf 'google_logging_project_sink\tprojects/%s/sinks/%s\n' "$PROJECT_ID" "$LOGGING_SINK" ;;
    topic)             printf 'google_pubsub_topic\tprojects/%s/topics/%s\n' "$PROJECT_ID" "$PUBSUB_TOPIC" ;;
    global-secret)     printf 'google_secret_manager_secret\tprojects/%s/secrets/%s\n' "$PROJECT_ID" "$GLOBAL_SECRET" ;;
    regional-secret)   printf 'google_secret_manager_regional_secret\tprojects/%s/locations/%s/secrets/%s\n' "$PROJECT_ID" "$REGION" "$REGIONAL_SECRET" ;;
    function-sa)       printf 'google_service_account\tprojects/%s/serviceAccounts/%s\n' "$PROJECT_ID" "$(ir_sa_email "$FUNCTION_SA_ACCOUNT_ID")" ;;
    sa)                printf 'google_service_account\tprojects/%s/serviceAccounts/%s\n' "$PROJECT_ID" "$(ir_sa_email "$SA_ACCOUNT_ID")" ;;
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
    flowlogs-function)
      value=$(gcloud functions describe "$FLOWLOGS_FUNCTION_NAME" --region="$REGION" --project="$PROJECT_ID" --no-gen2 \
        --format='value(eventTrigger.resource)' 2>/dev/null) || value='?'
      echo "trigger: ${value:--}" ;;
    org-sink | project-sink)
      if [[ "$1" == org-sink ]]; then
        value=$(gcloud logging sinks describe "$LOGGING_SINK" --organization="$ORGANIZATION_ID" --format='value(destination)' 2>/dev/null) || value='?'
      else
        value=$(gcloud logging sinks describe "$LOGGING_SINK" --project="$PROJECT_ID" --format='value(destination)' 2>/dev/null) || value='?'
      fi
      if [[ -n "$value" && "$value" != '?' && "$value" != *"/projects/$PROJECT_ID/"* ]]; then
        value+=" (another project: may feed a live integration)"
      fi
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
      echo "$(ir_count gcloud iam service-accounts keys list --iam-account="$email" --managed-by=user \
          --project="$PROJECT_ID" --format='value(name)') user-managed keys," \
        "$(ir_count gcloud projects get-iam-policy "$PROJECT_ID" --flatten='bindings[].members' \
          --filter="bindings.members:serviceAccount:$email" --format='value(bindings.role)') project roles" ;;
  esac
}
