#!/bin/bash
# Deploys the Stream Security file collector with gcloud, without Terraform: a function that
# sends every file written to a Cloud Storage bucket to Stream Security, such as the audit log
# GitHub Enterprise streams into the bucket. It deploys the function_source of
# modules/gcs-file-collector and names its resources as the module does.
# Run with --uninstall to remove it. Run with --help for the options.
set -euo pipefail

REPO=streamsec-terraform/terraform-streamsec-google-integration
RUNTIME=python312
EVENT_TYPE=google.cloud.storage.object.v1.finalized

APIS=(
  artifactregistry.googleapis.com
  cloudbuild.googleapis.com
  cloudfunctions.googleapis.com
  eventarc.googleapis.com
  iam.googleapis.com
  pubsub.googleapis.com
  run.googleapis.com
  secretmanager.googleapis.com
  storage.googleapis.com
)

PROJECT_ID=""
BUCKET=""
API_URL=""
API_URL_SUFFIX=github-audit
REGION=us-central1
REF=main
UNINSTALL=false
ASSUME_YES=false

usage() {
  cat <<EOF
Usage: bash deploy-gcs-file-collector.sh --project ID --bucket NAME --api-url URL [options]

Sends every file written to a Cloud Storage bucket to Stream Security, e.g. the audit log
GitHub Enterprise streams into the bucket. The collection token is read from
STREAMSEC_COLLECTION_TOKEN, or asked for without echo.

Options:
  --project ID            GCP project that holds the bucket; the collector is deployed there
  --bucket NAME           Bucket the files are written to (without gs://)
  --api-url URL           The URL you open Stream Security at, e.g. https://app.streamsec.io
  --api-url-suffix NAME   Stream Security collection endpoint (default: $API_URL_SUFFIX)
  --region REGION         Region of the function (default: $REGION)
  --ref REF               Release of $REPO to deploy the function from,
                          when this script does not run from a checkout of it (default: $REF)
  --uninstall             Remove the collector
  --yes                   Do not ask for confirmation
  -h, --help              Show this help
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

step() {
  echo
  echo "==> $*"
}

info() {
  echo "    $*"
}

interactive() {
  [ -t 0 ]
}

confirm() {
  local answer
  "$ASSUME_YES" && return 0
  interactive || die "Nothing changed. Run with --yes to continue without a prompt."
  read -r -p "$1 [y/N] " answer
  case "$answer" in
    [Yy]*) return 0 ;;
    *) die "Cancelled, nothing changed." ;;
  esac
}

# Retries a command a few times, quietly: IAM changes on a new service account can fail until
# the account has propagated. The command's error is shown only if every attempt fails.
retry() {
  local attempt=1 output
  until output=$("$@" 2>&1); do
    if [ "$attempt" -ge 6 ]; then
      printf '%s\n' "$output" >&2
      return 1
    fi
    info "The new identity is not visible to Google yet, retrying in 10 seconds..."
    sleep 10
    attempt=$((attempt + 1))
  done
}

# Runs a command without its chatter, showing its output only if it fails
quiet() {
  local output
  output=$("$@" 2>&1) || { printf '%s\n' "$output" >&2; return 1; }
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --project) PROJECT_ID=${2:-}; shift 2 ;;
      --bucket) BUCKET=${2:-}; shift 2 ;;
      --api-url) API_URL=${2:-}; shift 2 ;;
      --api-url-suffix) API_URL_SUFFIX=${2:-}; shift 2 ;;
      --region) REGION=${2:-}; shift 2 ;;
      --ref) REF=${2:-}; shift 2 ;;
      --uninstall) UNINSTALL=true; shift ;;
      --yes) ASSUME_YES=true; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; die "Unknown option: $1" ;;
    esac
  done

  [[ "$PROJECT_ID" =~ ^[a-z][-a-z0-9]{4,28}[a-z0-9]$ ]] || die "--project must be a GCP project ID, got '$PROJECT_ID'."
  [[ "$BUCKET" =~ ^[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]$ ]] || die "--bucket must be a bucket name without gs://, got '$BUCKET'."
  [[ "$API_URL_SUFFIX" =~ ^[a-z0-9]+([/-][a-z0-9]+)*$ ]] || die "--api-url-suffix must be a collection endpoint such as github-audit."
  [[ "$REGION" =~ ^[a-z]+-[a-z]+[0-9]+$ ]] || die "--region must be a GCP region such as us-central1."
  if ! "$UNINSTALL"; then
    [[ "$API_URL" =~ ^https://[^/[:space:]]+/?$ ]] || die "--api-url must be the https:// URL you open Stream Security at."
    API_URL=${API_URL%/}
    [[ "$REF" =~ ^[A-Za-z0-9._/-]+$ ]] || die "--ref must be a release tag or branch."
  fi
}

# The names modules/gcs-file-collector gives: one collector per endpoint and bucket.
set_names() {
  local slug hash
  slug=$(printf '%s' "${API_URL_SUFFIX//\//-}" | cut -c1-12 | sed 's/^-*//; s/-*$//')
  if command -v sha256sum >/dev/null; then
    hash=$(printf '%s' "$API_URL_SUFFIX|$BUCKET" | sha256sum | cut -c1-6)
  else
    hash=$(printf '%s' "$API_URL_SUFFIX|$BUCKET" | shasum -a 256 | cut -c1-6)
  fi
  SUFFIX="$slug-$hash"
  FUNCTION="streamsec-$SUFFIX"
  SERVICE_ACCOUNT="ss-col-$SUFFIX@$PROJECT_ID.iam.gserviceaccount.com"
  BUILD_SERVICE_ACCOUNT="ss-bld-$SUFFIX@$PROJECT_ID.iam.gserviceaccount.com"
  SECRET="streamsec-collector-token-$SUFFIX"
}

service_account_exists() {
  gcloud iam service-accounts describe "$1" --project "$PROJECT_ID" >/dev/null 2>&1
}

create_service_account() {
  if service_account_exists "$1"; then
    info "Using existing $1"
  else
    gcloud iam service-accounts create "${1%%@*}" --project "$PROJECT_ID" --display-name "$2" >/dev/null
    info "Created $1"
  fi
}

grant_project_role() {
  retry gcloud projects add-iam-policy-binding "$PROJECT_ID" --member "$1" --role "$2" --condition="${3:-None}" --quiet
}

# What the builder may touch in Cloud Storage: only the buckets Cloud Functions builds from, as in
# modules/gcs-file-collector, not every bucket of the project.
build_objects_condition() {
  local buckets="resource.name.startsWith('projects/_/buckets/gcf-v2-sources-$1-')"
  buckets+=" || resource.name.startsWith('projects/_/buckets/gcf-v2-uploads-$1-')"
  buckets+=" || resource.name.startsWith('projects/_/buckets/run-sources-$PROJECT_ID-')"
  echo "expression=resource.type == 'storage.googleapis.com/Object' && ($buckets),title=CollectorFunctionBuildObjects"
}

# The function_source next to this script in a checkout, or else the one of release $REF,
# downloaded into WORK_DIR.
function_source() {
  local here="" dir archive="$WORK_DIR/source.tar.gz"
  [ -f "${BASH_SOURCE[0]}" ] && here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [ -n "$here" ] && [ -f "$here/../modules/gcs-file-collector/function_source/main.py" ]; then
    echo "$here/../modules/gcs-file-collector/function_source"
    return
  fi
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$REF" -o "$archive" || die "Could not download $REPO at $REF."
  tar -xzf "$archive" -C "$WORK_DIR"
  dir=$(find "$WORK_DIR" -type d -path '*/modules/gcs-file-collector/function_source' | head -n 1)
  [ -n "$dir" ] || die "$REPO at $REF has no modules/gcs-file-collector."
  echo "$dir"
}

install() {
  local described location bucket_project project_number token storage_agent source state created=false

  WORK_DIR=$(mktemp -d)
  trap 'rm -rf "$WORK_DIR"' EXIT
  # stderr apart, so that a warning is not read as the bucket's location
  described=$(gcloud storage buckets describe "gs://$BUCKET" --project "$PROJECT_ID" --raw \
    --format='value(location,projectNumber)' 2>"$WORK_DIR/error") ||
    die "Cannot read bucket $BUCKET: $(cat "$WORK_DIR/error")"
  read -r location bucket_project <<<"$described"
  project_number=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
  # Eventarc delivers Cloud Storage events only to triggers in the bucket's project
  [ "$bucket_project" = "$project_number" ] ||
    die "Bucket $BUCKET is not in project $PROJECT_ID. Run this with --project set to the bucket's project."
  location=$(printf '%s' "$location" | tr '[:upper:]' '[:lower:]')
  # Before any change: a release that can't be downloaded or has no collector stops here
  source=$(function_source)

  step "This will set up, in project $PROJECT_ID:"
  info "Secret:           $SECRET, holding the collection token"
  info "Service accounts: $SERVICE_ACCOUNT (reads gs://$BUCKET)"
  info "                  $BUILD_SERVICE_ACCOUNT (builds the function)"
  info "Function:         $FUNCTION in $REGION, sending each new file in gs://$BUCKET"
  info "                  to $API_URL/api/v1/collection/$API_URL_SUFFIX"
  confirm "Continue?"

  step "Enabling APIs"
  gcloud services enable "${APIS[@]}" --project "$PROJECT_ID"

  step "Collection token"
  token=${STREAMSEC_COLLECTION_TOKEN:-}
  if [ -z "$token" ] && interactive; then
    read -r -s -p "Stream Security collection token (not shown): " token
    echo
  fi
  if gcloud secrets describe "$SECRET" --project "$PROJECT_ID" >/dev/null 2>&1; then
    if [ -n "$token" ]; then
      printf '%s' "$token" | quiet gcloud secrets versions add "$SECRET" --project "$PROJECT_ID" --data-file=-
      info "Stored the token as a new version of $SECRET"
    else
      info "Using the token in existing secret $SECRET"
    fi
  else
    [ -n "$token" ] || die "Set STREAMSEC_COLLECTION_TOKEN or run interactively to enter the collection token."
    printf '%s' "$token" | quiet gcloud secrets create "$SECRET" --project "$PROJECT_ID" \
      --replication-policy automatic --data-file=-
    info "Created secret $SECRET"
  fi
  token=

  step "Service accounts"
  service_account_exists "$SERVICE_ACCOUNT" && service_account_exists "$BUILD_SERVICE_ACCOUNT" || created=true
  create_service_account "$SERVICE_ACCOUNT" "Stream Security file collector"
  create_service_account "$BUILD_SERVICE_ACCOUNT" "Stream Security file collector builder"
  retry gcloud secrets add-iam-policy-binding "$SECRET" --project "$PROJECT_ID" \
    --member "serviceAccount:$SERVICE_ACCOUNT" --role roles/secretmanager.secretAccessor
  info "The collector can read secret $SECRET"
  retry gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
    --member "serviceAccount:$SERVICE_ACCOUNT" --role roles/storage.objectViewer
  info "The collector can read gs://$BUCKET"
  grant_project_role "serviceAccount:$SERVICE_ACCOUNT" roles/eventarc.eventReceiver
  info "The collector can receive the bucket's events"
  grant_project_role "serviceAccount:$BUILD_SERVICE_ACCOUNT" roles/logging.logWriter
  grant_project_role "serviceAccount:$BUILD_SERVICE_ACCOUNT" roles/artifactregistry.writer
  grant_project_role "serviceAccount:$BUILD_SERVICE_ACCOUNT" roles/storage.objectUser \
    "$(build_objects_condition "$project_number")"
  info "The builder can build the function"
  storage_agent=$(gcloud storage service-agent --project "$PROJECT_ID")
  grant_project_role "serviceAccount:$storage_agent" roles/pubsub.publisher
  info "Cloud Storage can publish the bucket's events"

  step "Deploying function $FUNCTION (takes a few minutes)"
  if ! deploy "$source" "$location"; then
    "$created" || die "Deploying $FUNCTION failed."
    # A first build can start before the new builder's permissions apply
    info "Retrying in 60 seconds, while the new service accounts' permissions apply..."
    sleep 60
    deploy "$source" "$location" || die "Deploying $FUNCTION failed."
  fi
  retry gcloud functions add-invoker-policy-binding "$FUNCTION" --project "$PROJECT_ID" \
    --region "$REGION" --member "serviceAccount:$SERVICE_ACCOUNT"
  info "Only $SERVICE_ACCOUNT can invoke the function"

  step "Checking the result"
  state=$(gcloud functions describe "$FUNCTION" --project "$PROJECT_ID" --region "$REGION" --format='value(state)')
  [ "$state" = ACTIVE ] || die "Function $FUNCTION is $state, expected ACTIVE."
  info "Function $FUNCTION is ACTIVE"

  cat <<EOF

Done. Each file written to gs://$BUCKET from now on reaches Stream Security within a minute.

To check, list the function's recent runs once files arrive; each sent file logs "Sent gs://...":
  gcloud functions logs read $FUNCTION --project $PROJECT_ID --region $REGION --limit 10
On a first install, deliveries in the first minutes can fail with 403 while Google applies the
new service account's permissions. Eventarc retries them, so those files arrive a little later.

To remove this setup:
  bash deploy-gcs-file-collector.sh --project $PROJECT_ID --bucket $BUCKET --api-url-suffix $API_URL_SUFFIX --region $REGION --uninstall
EOF
}

deploy() {
  gcloud functions deploy "$FUNCTION" --gen2 --project "$PROJECT_ID" --region "$REGION" \
    --runtime "$RUNTIME" --source "$1" --entry-point collect \
    --trigger-event-filters "type=$EVENT_TYPE" --trigger-event-filters "bucket=$BUCKET" \
    --trigger-location "$2" --trigger-service-account "$SERVICE_ACCOUNT" --retry \
    --service-account "$SERVICE_ACCOUNT" \
    --build-service-account "projects/$PROJECT_ID/serviceAccounts/$BUILD_SERVICE_ACCOUNT" \
    --memory 512Mi --timeout 120s --max-instances 10 \
    --set-env-vars "API_URL=$API_URL,API_URL_SUFFIX=$API_URL_SUFFIX" \
    --set-secrets "API_TOKEN=$SECRET:latest" \
    --quiet --format none
}

uninstall() {
  step "This will remove, from project $PROJECT_ID:"
  info "Function $FUNCTION in $REGION, secret $SECRET,"
  info "service accounts $SERVICE_ACCOUNT and $BUILD_SERVICE_ACCOUNT, and their access to gs://$BUCKET"
  confirm "Continue?"

  step "Removing"
  if gcloud functions describe "$FUNCTION" --project "$PROJECT_ID" --region "$REGION" >/dev/null 2>&1; then
    gcloud functions delete "$FUNCTION" --project "$PROJECT_ID" --region "$REGION" --quiet
    info "Deleted function $FUNCTION"
  else
    info "Function $FUNCTION not found in $REGION, skipping"
  fi
  if gcloud secrets describe "$SECRET" --project "$PROJECT_ID" >/dev/null 2>&1; then
    quiet gcloud secrets delete "$SECRET" --project "$PROJECT_ID" --quiet
    info "Deleted secret $SECRET"
  else
    info "Secret $SECRET not found, skipping"
  fi
  if service_account_exists "$SERVICE_ACCOUNT"; then
    # Bindings of a deleted account stay behind as deleted:serviceAccount:... members
    quiet gcloud storage buckets remove-iam-policy-binding "gs://$BUCKET" \
      --member "serviceAccount:$SERVICE_ACCOUNT" --role roles/storage.objectViewer || true
    quiet gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
      --member "serviceAccount:$SERVICE_ACCOUNT" --role roles/eventarc.eventReceiver --condition=None || true
    quiet gcloud iam service-accounts delete "$SERVICE_ACCOUNT" --project "$PROJECT_ID" --quiet
    info "Deleted service account $SERVICE_ACCOUNT"
  else
    info "Service account $SERVICE_ACCOUNT not found, skipping"
  fi
  if service_account_exists "$BUILD_SERVICE_ACCOUNT"; then
    for role in roles/logging.logWriter roles/artifactregistry.writer roles/storage.objectUser; do
      # --all: the storage.objectUser binding has a condition
      quiet gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
        --member "serviceAccount:$BUILD_SERVICE_ACCOUNT" --role "$role" --all || true
    done
    quiet gcloud iam service-accounts delete "$BUILD_SERVICE_ACCOUNT" --project "$PROJECT_ID" --quiet
    info "Deleted service account $BUILD_SERVICE_ACCOUNT"
  else
    info "Service account $BUILD_SERVICE_ACCOUNT not found, skipping"
  fi

  echo
  echo "Done. Files written to gs://$BUCKET are no longer sent to Stream Security."
}

main() {
  parse_args "$@"
  set_names
  if "$UNINSTALL"; then uninstall; else install; fi
}

main "$@"
