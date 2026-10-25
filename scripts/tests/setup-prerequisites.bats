#!/usr/bin/env bats
# The leftover check in setup-prerequisites.sh, against the fake gcloud in tests/bin.

load helpers

SETUP="$BATS_TEST_DIRNAME/../setup-prerequisites.sh"
FN_SA=stream-security-function-sa@p1.iam.gserviceaccount.com
SA=stream-security@p1.iam.gserviceaccount.com
TOPIC_ROW=$'google_pubsub_topic\tprojects/p1/topics/stream-security-events-topic'
FN_SA_ROW=$'google_service_account\tprojects/p1/serviceAccounts/'"$FN_SA"

setup() { setup_fakes; }

# Project-only mode from step 6: the leftover check is all that runs before the preview.
run_setup() {
  run bash "$SETUP" --project-only --project-id p1 --region us-central1 \
    --streamsec-host h.example --workspace-id w --api-token t \
    --git-ref v0.0.0 --skip-permission-check --start-from-step 6 --yes "$@"
}

run_check() {
  run bash "$SETUP" --project-id p1 --region us-central1 --check-leftovers "$@"
}

@test "(a) a clean project passes the check and goes on to the preview" {
  run_setup
  [ "$status" -eq 0 ]
  [[ "$output" == *"No leftovers"* ]]
  [[ "$output" == *"Step 6/6"* ]]
  grep -q 'previews?previewId=' "$FAKE_DIR/curl.log"
  refute_called ' delete '
}

@test "the check runs after step 5 and before step 6" {
  run bash "$SETUP" --project-only --project-id p1 --region us-central1 \
    --streamsec-host h.example --workspace-id w --api-token t \
    --git-ref v0.0.0 --skip-permission-check --yes
  [ "$status" -eq 0 ]
  step5=$(line_of "Step 5/6") check=$(line_of "Checking for resources left over") step6=$(line_of "Step 6/6")
  [ -n "$step5" ] && [ -n "$check" ] && [ -n "$step6" ]
  [ "$step5" -lt "$check" ] && [ "$check" -lt "$step6" ]
}

@test "(b) an unowned topic and function SA stop the run before the preview" {
  exist topic:stream-security-events-topic "sa:$FN_SA"
  run_setup
  [ "$status" -eq 1 ]
  [[ "$output" == *"Pub/Sub topic: stream-security-events-topic"* ]]
  [[ "$output" == *"Function service account: $FN_SA"* ]]
  [[ "$output" == *"0 subscriptions, 0 IAM bindings"* ]]
  [[ "$output" == *"0 user-managed keys, 0 project roles"* ]]
  [[ "$output" == *"cleanup-abandoned-deployment.sh --project-id p1 --region us-central1 --only topic,function-sa --pubsub-topic stream-security-events-topic --function-sa-id stream-security-function-sa"* ]]
  [[ "$output" == *"--cleanup-leftovers"* ]]
  [[ "$output" != *"Step 6/6"* ]]
  refute_preview
  refute_called ' delete '
}

@test "(c) resources in the deployment's state are a re-apply, not leftovers" {
  exist topic:stream-security-events-topic "sa:$FN_SA"
  deployment streamsec-integration ACTIVE "$TOPIC_ROW"$'\tUNCHANGED\tRECONCILED' "$FN_SA_ROW"$'\tUNCHANGED\tRECONCILED'
  run_setup
  [ "$status" -eq 0 ]
  [[ "$output" == *"No leftovers"* ]]
  [[ "$output" == *"Step 6/6"* ]]
  called 'resources list --revision=projects/p1/locations/us-central1/deployments/streamsec-integration/revisions/r-1'
  called 'deployments list --project=p1 --location=- '
  grep -q '"deployment": "projects/p1/locations/us-central1/deployments/streamsec-integration"' "$FAKE_DIR/curl.body"
}

@test "(d) --cleanup-leftovers --yes deletes in dependency order, then continues" {
  exist function2:stream-security-events-function project-sink:stream-security-events-sink \
    topic:stream-security-events-topic "sa:$FN_SA" "sa:$SA"
  run_setup --cleanup-leftovers
  [ "$status" -eq 0 ]
  assert_called_before 'logging sinks delete stream-security-events-sink' 'pubsub topics delete stream-security-events-topic'
  assert_called_before 'functions delete stream-security-events-function' 'pubsub topics delete stream-security-events-topic'
  assert_called_before 'functions delete stream-security-events-function' "service-accounts delete $FN_SA"
  called "service-accounts delete $SA"
  [ ! -s "$FAKE_DIR/existing" ]
  [[ "$output" == *"Step 6/6"* ]]
}

@test "--cleanup-leftovers leaves the deployment's own resources alone" {
  exist topic:stream-security-events-topic "sa:$FN_SA"
  deployment streamsec-integration ACTIVE "$TOPIC_ROW"$'\tUNCHANGED\tRECONCILED'
  run_setup --cleanup-leftovers
  [ "$status" -eq 0 ]
  called "service-accounts delete $FN_SA"
  refute_called 'pubsub topics delete'
}

@test "a deployment of another name owns its resources too, and they are never deleted" {
  exist topic:stream-security-events-topic "sa:$FN_SA"
  deployment my-stream-deployment ACTIVE "$TOPIC_ROW"$'\tUNCHANGED\tRECONCILED' "$FN_SA_ROW"$'\tUNCHANGED\tRECONCILED'
  run_setup --cleanup-leftovers
  [ "$status" -eq 0 ]
  [[ "$output" == *"Owned by a deployment other than 'streamsec-integration'"* ]]
  [[ "$output" == *"Pub/Sub topic: stream-security-events-topic: my-stream-deployment (us-central1)"* ]]
  refute_called ' delete '
}

@test "the 409 rows of a failed apply (no id) don't make a leftover owned" {
  exist topic:stream-security-events-topic "sa:$FN_SA" "sa:$SA"
  deployment streamsec-integration FAILED $'google_pubsub_topic\t\tCREATE\tFAILED' $'google_service_account\t\tCREATE\tFAILED' \
    $'google_service_account\tprojects/p1/serviceAccounts/'"$SA"$'\tCREATE\tRECONCILED'
  run_setup
  [ "$status" -eq 1 ]
  [[ "$output" == *"--only topic,function-sa --"* ]]
}

@test "a latest revision that lists nothing falls back to the newest one that does" {
  exist topic:stream-security-events-topic "sa:$FN_SA"
  deployment streamsec-integration FAILED
  older_revision streamsec-integration r-0 "$TOPIC_ROW"$'\tCREATE\tRECONCILED' "$FN_SA_ROW"$'\tCREATE\tRECONCILED'
  run_setup --cleanup-leftovers
  [ "$status" -eq 0 ]
  [[ "$output" == *"No leftovers"* ]]
  refute_called ' delete '
}

@test "a resource the latest revision deleted is not owned" {
  exist topic:stream-security-events-topic
  deployment streamsec-integration ACTIVE "$TOPIC_ROW"$'\tDELETE\tRECONCILED'
  run_setup
  [ "$status" -eq 1 ]
  [[ "$output" == *"--only topic --"* ]]
}

@test "any deployment mid-apply stops the check rather than guess" {
  exist topic:stream-security-events-topic
  deployment some-other-deployment UPDATING
  run_setup --cleanup-leftovers
  [ "$status" -eq 1 ]
  [[ "$output" == *"'some-other-deployment' (us-central1) is UPDATING"* ]]
  refute_preview
  refute_called ' delete '
}

@test "unreadable deployments stop the check and delete nothing" {
  exist topic:stream-security-events-topic
  echo "ERROR: (gcloud.infra-manager.deployments.list) PERMISSION_DENIED: denied" >"$FAKE_DIR/list-error"
  run_setup --cleanup-leftovers
  [ "$status" -eq 1 ]
  [[ "$output" == *PERMISSION_DENIED* ]]
  refute_preview
  refute_called ' delete '
}

@test "a leftover that fails to delete stops the run before the preview" {
  exist topic:stream-security-events-topic "sa:$FN_SA"
  echo topic:stream-security-events-topic >"$FAKE_DIR/fail-delete"
  run_setup --cleanup-leftovers
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not delete Pub/Sub topic"* ]]
  called "service-accounts delete $FN_SA"
  [[ "$output" != *"Step 6/6"* ]]
}

@test "the environment can't change which names are checked or deleted" {
  exist topic:stream-security-events-topic topic:someone-elses-topic
  PUBSUB_TOPIC=someone-elses-topic run_setup --cleanup-leftovers
  [ "$status" -eq 0 ]
  called 'pubsub topics delete stream-security-events-topic'
  refute_called 'someone-elses-topic'
}

@test "the global collection-token secret is not checked: the apply never creates it" {
  exist secret:stream-security-collection-token
  run_setup --cleanup-leftovers
  [ "$status" -eq 0 ]
  refute_called 'stream-security-collection-token'
}

@test "--check-leftovers needs no StreamSecurity credentials and changes nothing" {
  exist topic:stream-security-events-topic
  run_check --project-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"Pub/Sub topic: stream-security-events-topic"* ]]
  [[ "$output" != *"Step 1/6"* ]]
  refute_called ' (delete|create|enable|add-iam-policy-binding|update) '
}

@test "--check-leftovers exits 0 on a clean project" {
  run_check --project-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"No leftovers"* ]]
}

@test "--check-leftovers --cleanup-leftovers asks first, and a no deletes nothing" {
  exist topic:stream-security-events-topic
  run bash -c 'echo n | bash "$0" --project-only --project-id p1 --region us-central1 --check-leftovers --cleanup-leftovers' "$SETUP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Aborted."* ]]
  refute_called ' delete '
}

@test "org mode checks the org-level sink, and the printed command passes --org-id" {
  exist org-sink:stream-security-events-sink
  run_check --org-id 123
  [ "$status" -eq 1 ]
  [[ "$output" == *"Org logging sink: stream-security-events-sink"* ]]
  [[ "$output" == *"--region us-central1 --org-id 123 --only org-sink --logging-sink stream-security-events-sink"* ]]
  refute_called 'sinks describe stream-security-events-sink --project='
}

@test "deleting an org sink takes the typed confirmation, not a y" {
  exist org-sink:stream-security-events-sink
  run bash -c 'echo y | bash "$0" --org-id 123 --project-id p1 --region us-central1 --check-leftovers --cleanup-leftovers' "$SETUP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Aborted."* ]]
  refute_called ' delete '
}

@test "an unowned sink that writes to another project is never offered for deletion" {
  exist org-sink:stream-security-events-sink
  echo "pubsub.googleapis.com/projects/p2/topics/stream-security-events-topic" >"$FAKE_DIR/sink-destination"
  run_check --org-id 123 --cleanup-leftovers --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"writes to pubsub.googleapis.com/projects/p2/topics/stream-security-events-topic"* ]]
  [[ "$output" == *"gcloud logging sinks delete stream-security-events-sink --organization=123"* ]]
  refute_called ' delete '
}

@test "the regional secret is checked through the regional endpoint" {
  exist regional-secret:stream-security
  run_check --project-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"Regional secret: stream-security (us-central1)"* ]]
  called 'secrets describe stream-security --location=us-central1 --project=p1 \[endpoint=https://secretmanager.us-central1.rep.googleapis.com/\]'
}

@test "without the lib next to it, setup warns and skips the check" {
  cp "$SETUP" "$BATS_TEST_TMPDIR/setup-prerequisites.sh"
  exist topic:stream-security-events-topic
  run bash "$BATS_TEST_TMPDIR/setup-prerequisites.sh" --project-only --project-id p1 --region us-central1 \
    --streamsec-host h.example --workspace-id w --api-token t \
    --git-ref v0.0.0 --skip-permission-check --start-from-step 6 --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping the check"* ]]
  [[ "$output" == *"Step 6/6"* ]]
  run bash "$BATS_TEST_TMPDIR/setup-prerequisites.sh" --project-only --project-id p1 --region us-central1 --check-leftovers
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "piped into bash, setup runs without the check and never sources ./lib" {
  cd "$BATS_TEST_TMPDIR"
  mkdir -p lib && echo 'echo PLANTED-LIB-SOURCED' >lib/integration-resources.sh
  run bash -s -- --project-only --project-id p1 --region us-central1 \
    --streamsec-host h.example --workspace-id w --api-token t \
    --git-ref v0.0.0 --skip-permission-check --start-from-step 6 --yes <"$SETUP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping the check"* ]]
  [[ "$output" != *PLANTED-LIB-SOURCED* ]]
  [[ "$output" == *"Step 6/6"* ]]
}

@test "a deleted deployment owns nothing" {
  exist topic:stream-security-events-topic
  deployment streamsec-integration DELETED "$TOPIC_ROW"$'	UNCHANGED	RECONCILED'
  run_setup
  [ "$status" -eq 1 ]
  [[ "$output" == *"--only topic --"* ]]
}

@test "a resource it may not read is a warning, never a deletion, and doesn't block the run" {
  exist topic:stream-security-events-topic
  echo topic:stream-security-events-topic >"$FAKE_DIR/describe-errors"
  run_setup --cleanup-leftovers
  [ "$status" -eq 0 ]
  [[ "$output" == *PERMISSION_DENIED* ]]
  [[ "$output" == *"Could not check these"* ]]
  [[ "$output" == *"Step 6/6"* ]]
  refute_called ' delete '
}

# What a whole abandoned integration leaves: the module's eventarc subscription, SA key and secret accessor.
abandoned_integration() {
  exist function2:stream-security-events-function project-sink:stream-security-events-sink \
    topic:stream-security-events-topic regional-secret:stream-security "sa:$FN_SA" "sa:$SA"
  echo projects/p1/subscriptions/eventarc-us-central1-stream-security-events-function-sub >"$FAKE_DIR/subscriptions"
  printf '%s\t%s\n' "$SA" 45e8260cbea2c75cded6299b995e301a202abd48 >"$FAKE_DIR/keys"
}

@test "--yes deletes nothing while a leftover looks in use" {
  abandoned_integration
  run_setup --cleanup-leftovers
  [ "$status" -eq 1 ]
  [[ "$output" == *"Pub/Sub topic: stream-security-events-topic (subscriptions: 1)"* ]]
  [[ "$output" == *"Service account: $SA (user-managed keys: 1)"* ]]
  [[ "$output" == *"With --yes nothing is deleted while a leftover looks in use"* ]]
  refute_called ' delete '
  refute_preview
}

@test "an abandoned integration is deleted after an interactive yes, in dependency order" {
  abandoned_integration
  run bash -c 'echo y | bash "$0" --project-only --project-id p1 --region us-central1 --check-leftovers --cleanup-leftovers' "$SETUP"
  [ "$status" -eq 0 ]
  assert_called_before 'functions delete stream-security-events-function' 'pubsub topics delete'
  assert_called_before 'logging sinks delete' 'pubsub topics delete'
  assert_called_before 'functions delete stream-security-events-function' "service-accounts delete $FN_SA"
  [ ! -s "$FAKE_DIR/existing" ]
}

@test "an exported CDPATH doesn't hide the lib" {
  exist topic:stream-security-events-topic
  local dir
  dir=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  cd "$(dirname "$dir")"
  # CDPATH only applies to a relative path, so run the script by one.
  CDPATH=.:/tmp run bash "$(basename "$dir")/setup-prerequisites.sh" \
    --project-only --project-id p1 --region us-central1 --check-leftovers
  [ "$status" -eq 1 ]
  [[ "$output" == *"Pub/Sub topic: stream-security-events-topic"* ]]
}

@test "--skip-leftover-check can't be combined with the leftover modes" {
  run_check --project-only --skip-leftover-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"can't be combined"* ]]
  [ ! -s "$FAKE_DIR/gcloud.log" ]
}

@test "CLEANUP_LEFTOVERS in the environment doesn't turn on deletion" {
  exist topic:stream-security-events-topic
  CLEANUP_LEFTOVERS=true run_setup
  [ "$status" -eq 1 ]
  refute_called ' delete '
}

@test "--skip-leftover-check goes straight on to the preview" {
  exist topic:stream-security-events-topic
  run_setup --skip-leftover-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping the check (--skip-leftover-check)"* ]]
  [[ "$output" == *"Step 6/6"* ]]
  refute_called 'deployments list'
}

@test "a region that isn't a region is rejected before any call" {
  run_check --project-only --region 'evil.example/x'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid --region"* ]]
  [ ! -s "$FAKE_DIR/gcloud.log" ]
}

@test "a location Infrastructure Manager can't reach stops the check" {
  exist topic:stream-security-events-topic
  echo '{"unreachable": ["projects/p1/locations/europe-west1"]}' >"$FAKE_DIR/curl-stdout"
  run_setup --cleanup-leftovers
  [ "$status" -eq 1 ]
  [[ "$output" == *"can't reach some locations"* ]]
  refute_called ' delete '
  refute_preview
}

@test "failing to ask which locations are reachable stops the check" {
  exist topic:stream-security-events-topic
  touch "$FAKE_DIR/curl-fail"
  run_check --project-only --cleanup-leftovers --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not ask Infrastructure Manager"* ]]
  [[ "$output" == *"returned error: 403"* ]]
  [[ "$output" == *"--skip-leftover-check"* ]]
  refute_called ' delete '
}

@test "a state id written with the project number is owned too" {
  exist topic:stream-security-events-topic
  deployment streamsec-integration ACTIVE $'google_pubsub_topic\tprojects/123456789/topics/stream-security-events-topic\tUNCHANGED\tRECONCILED'
  run_setup
  [ "$status" -eq 0 ]
  [[ "$output" == *"No leftovers"* ]]
}

@test "a same-named resource in another project or region doesn't make ours owned" {
  exist topic:stream-security-events-topic function2:stream-security-events-function
  deployment streamsec-integration ACTIVE \
    $'google_pubsub_topic\tprojects/p2/topics/stream-security-events-topic\tUNCHANGED\tRECONCILED' \
    $'google_cloudfunctions2_function\tprojects/p1/locations/europe-west1/functions/stream-security-events-function\tUNCHANGED\tRECONCILED'
  run_setup
  [ "$status" -eq 1 ]
  [[ "$output" == *"--only events-function,topic --"* ]]
}

@test "every kind the apply creates is owned through its exact state id" {
  exist function2:stream-security-events-function project-sink:stream-security-events-sink \
    topic:stream-security-events-topic regional-secret:stream-security "sa:$FN_SA" "sa:$SA"
  deployment streamsec-integration ACTIVE \
    $'google_cloudfunctions2_function\tprojects/p1/locations/us-central1/functions/stream-security-events-function\tUNCHANGED\tRECONCILED' \
    $'google_logging_project_sink\tprojects/p1/sinks/stream-security-events-sink\tUNCHANGED\tRECONCILED' \
    "$TOPIC_ROW"$'\tUNCHANGED\tRECONCILED' \
    $'google_secret_manager_regional_secret\tprojects/p1/locations/us-central1/secrets/stream-security\tUNCHANGED\tRECONCILED' \
    "$FN_SA_ROW"$'\tUNCHANGED\tRECONCILED' \
    $'google_service_account\tprojects/p1/serviceAccounts/'"$SA"$'\tUNCHANGED\tRECONCILED'
  run_check --project-only --cleanup-leftovers --yes
  [ "$status" -eq 0 ]
  [ "$(grep -c 'yes     streamsec-integration (us-central1)' <<<"$output")" -eq 6 ]
  refute_called ' delete '
}

@test "an org sink is owned through its org-level state id" {
  exist org-sink:stream-security-events-sink
  deployment streamsec-integration ACTIVE \
    $'google_logging_organization_sink\torganizations/123/sinks/stream-security-events-sink\tUNCHANGED\tRECONCILED'
  run_check --org-id 123 --cleanup-leftovers --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"No leftovers"* ]]
  refute_called ' delete '
}

@test "an unreadable project number stops the check" {
  exist topic:stream-security-events-topic
  echo "ERROR: (gcloud.projects.describe) PERMISSION_DENIED: denied" >"$FAKE_DIR/project-error"
  run_check --project-only --cleanup-leftovers --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *PERMISSION_DENIED* ]]
  refute_called ' delete '
}

@test "a reachability answer that isn't {} stops the check" {
  exist topic:stream-security-events-topic
  echo '<html>proxy login</html>' >"$FAKE_DIR/curl-stdout"
  run_check --project-only --cleanup-leftovers --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"can't reach some locations"* ]]
  refute_called ' delete '
}

@test "the project role can bind an invoker on one Cloud Run service" {
  run bash "$SETUP" --project-only --project-id p1 --region us-central1 \
    --streamsec-host h.example --workspace-id w --api-token t \
    --git-ref v0.0.0 --skip-permission-check --start-from-step 2 --yes
  [ "$status" -eq 0 ]
  called 'roles create .*run\.services\.get[,[:space:]]'
  called 'roles create .*run\.services\.getIamPolicy'
  called 'roles create .*run\.services\.setIamPolicy'
}

@test "--enable-gke-logs reaches the preview inputs" {
  run_setup --enable-gke-logs
  [ "$status" -eq 0 ]
  grep -q '"enable_gke_logs": {"inputValue": "true"}' "$FAKE_DIR/curl.body"
}

@test "without --enable-gke-logs the inputs don't mention GKE, also on an existing deployment" {
  run_setup
  [ "$status" -eq 0 ]
  [ -s "$FAKE_DIR/curl.body" ]
  ! grep -q enable_gke_logs "$FAKE_DIR/curl.body"
  deployment streamsec-integration ACTIVE
  run_setup
  [ "$status" -eq 0 ]
  grep -q '"google_project_id"' "$FAKE_DIR/curl.body"
  ! grep -q enable_gke_logs "$FAKE_DIR/curl.body"
}

@test "--enable-gke-logs on an existing deployment adds the input and keeps the others" {
  deployment streamsec-integration ACTIVE
  run_setup --enable-gke-logs
  [ "$status" -eq 0 ]
  grep -q '"enable_gke_logs": {"inputValue": "true"}' "$FAKE_DIR/curl.body"
  grep -q '"google_project_id"' "$FAKE_DIR/curl.body"
}

@test "org mode passes --enable-gke-logs to the preview's --input-values" {
  run bash "$SETUP" --project-id p1 --org-id 123 --region us-central1 \
    --streamsec-host h.example --workspace-id w --api-token t \
    --git-ref v0.0.0 --skip-permission-check --start-from-step 6 --yes --enable-gke-logs
  [ "$status" -eq 0 ]
  called 'infra-manager previews create .*--input-values=[^ ]*enable_gke_logs=true'
}

@test "--enable-gke-logs on a CRLF deployment input replaces enable_gke_logs, not duplicates it" {
  deployment streamsec-integration ACTIVE
  printf '{\r\n  "enable_gke_logs": {\r\n    "inputValue": "false"\r\n  },\r\n  "include_projects": {\r\n    "inputValue": ["p1", "p,2"]\r\n  }\r\n}\r\n' >"$FAKE_DIR/input-values"
  run_setup --enable-gke-logs
  [ "$status" -eq 0 ]
  # One enable_gke_logs in each request: the preview and the update.
  [ "$(grep -o enable_gke_logs "$FAKE_DIR/curl.body" | wc -l)" -eq 2 ]
  grep -q '"enable_gke_logs": {"inputValue": "true"}' "$FAKE_DIR/curl.body"
  grep -q '"inputValue": \["p1", "p,2"\]' "$FAKE_DIR/curl.body"
}

@test "--enable-gke-logs: new deployment next steps list it; an existing deployment's update applies it" {
  run_setup --enable-gke-logs
  [ "$status" -eq 0 ]
  [[ "$output" == *"enable_gke_logs=true"* ]]
  deployment streamsec-integration ACTIVE
  : >"$FAKE_DIR/curl.body"
  run_setup --enable-gke-logs
  [ "$status" -eq 0 ]
  grep -q -- "-X PATCH" "$FAKE_DIR/curl.log"
  [ "$(grep -c '"enable_gke_logs": {"inputValue": "true"}' "$FAKE_DIR/curl.body")" -eq 2 ]
}

@test "--enable-gke-logs stops before the preview on a ref without the real-time GKE module" {
  echo 'variable "gke_bucket_name" {}' >"$FAKE_DIR/ref-variables"
  run_setup --enable-gke-logs
  [ "$status" -eq 1 ]
  [[ "$output" == *"Git ref v0.0.0 has no real-time GKE module"* ]]
  grep -q 'raw.githubusercontent.com/streamsec-terraform/terraform-streamsec-google-integration/v0.0.0/infrastructure-manager/variables.tf' "$FAKE_DIR/curl.log"
  refute_preview
}

@test "GKE logs stop before the preview when the project role lacks run.services.*" {
  exist project-role:StreamSecurityInfraManagerProjectRole
  echo 'pubsub.topics.create;run.services.get' >"$FAKE_DIR/role-permissions"
  run_setup --enable-gke-logs
  [ "$status" -eq 1 ]
  [[ "$output" == *"lacks run.services.* for GKE logs"*"--start-from-step 2"* ]]
  refute_preview
}

@test "GKE logs on in the deployment's inputs also need run.services.* in the project role" {
  exist project-role:StreamSecurityInfraManagerProjectRole
  echo 'pubsub.topics.create' >"$FAKE_DIR/role-permissions"
  deployment streamsec-integration ACTIVE
  printf '{\n  "enable_gke_logs": {\n    "inputValue": "true"\n  }\n}\n' >"$FAKE_DIR/input-values"
  run_setup
  [ "$status" -eq 1 ]
  [[ "$output" == *"lacks run.services.* for GKE logs"* ]]
  refute_preview
}

@test "GKE logs on in the deployment's inputs stop before the preview on a ref without the real-time GKE module" {
  echo 'variable "gke_bucket_name" {}' >"$FAKE_DIR/ref-variables"
  deployment streamsec-integration ACTIVE
  printf '{\n  "enable_gke_logs": {\n    "inputValue": "true"\n  }\n}\n' >"$FAKE_DIR/input-values"
  run_setup
  [ "$status" -eq 1 ]
  [[ "$output" == *"Git ref v0.0.0 has no real-time GKE module"* ]]
  refute_preview
}

@test "GKE logs stop when the project role lacks run.services.get" {
  exist project-role:StreamSecurityInfraManagerProjectRole
  echo 'run.services.getIamPolicy;run.services.setIamPolicy' >"$FAKE_DIR/role-permissions"
  run_setup --enable-gke-logs
  [ "$status" -eq 1 ]
  refute_preview
}

@test "GKE logs go on to the preview when the project role has run.services.*" {
  exist project-role:StreamSecurityInfraManagerProjectRole
  echo 'pubsub.topics.create;run.services.get;run.services.getIamPolicy;run.services.setIamPolicy' >"$FAKE_DIR/role-permissions"
  run_setup --enable-gke-logs
  [ "$status" -eq 0 ]
  grep -q 'previews?previewId=' "$FAKE_DIR/curl.log"
}

@test "--enable-gke-logs: the check never looks at GKE resources (their names have a random suffix)" {
  exist topic:streamsec-gke-audit-logs-0a1b2c3d org-sink:streamsec-gke-audit-logs-pubsub-0a1b2c3d
  run_check --org-id 123 --enable-gke-logs
  [ "$status" -eq 0 ]
  [[ "$output" == *"No leftovers"* ]]
  [[ "$output" != *GKE* ]]
  refute_called 'gke'
}

@test "an existing deployment with old bucket-based GKE inputs stops before the preview" {
  deployment streamsec-integration ACTIVE
  printf '{\n  "enable_gke_logs": {\n    "inputValue": "true"\n  },\n  "gke_bucket_name": {\n    "inputValue": "my-gke-logs"\n  }\n}\n' >"$FAKE_DIR/input-values"
  run_setup --enable-gke-logs
  [ "$status" -eq 1 ]
  [[ "$output" == *"has the old GKE module"*"enable_gke_logs = false"* ]]
  refute_preview
  printf '{\r\n  "gke_api_url": {\r\n    "inputValue": "https://app.streamsec.io"\r\n  }\r\n}\r\n' >"$FAKE_DIR/input-values"
  run_setup
  [ "$status" -eq 1 ]
  [[ "$output" == *"has the old GKE module"* ]]
  refute_preview
}

@test "GKE logs on with default inputs and the old module in the deployment's state stop before the preview" {
  deployment streamsec-integration ACTIVE $'google_logging_organization_sink\torganizations/123/sinks/streamsec-gke-audit-logs\tUNCHANGED\tRECONCILED'
  printf '{\n  "enable_gke_logs": {\n    "inputValue": "true"\n  }\n}\n' >"$FAKE_DIR/input-values"
  run_setup
  [ "$status" -eq 1 ]
  [[ "$output" == *"has the old GKE module"* ]]
  refute_preview
}

@test "an old GKE deployment updated to an old ref goes on (nothing changes for GKE)" {
  deployment streamsec-integration ACTIVE $'google_logging_organization_sink\torganizations/123/sinks/streamsec-gke-audit-logs\tUNCHANGED\tRECONCILED'
  printf '{\n  "enable_gke_logs": {\n    "inputValue": "true"\n  },\n  "gke_streamsec_token": {\n    "inputValue": "x"\n  }\n}\n' >"$FAKE_DIR/input-values"
  echo 'variable "gke_bucket_name" {}' >"$FAKE_DIR/ref-variables"
  run_setup
  [ "$status" -eq 0 ]
  [[ "$output" != *"has the old GKE module"* && "$output" != *"no real-time GKE module"* ]]
  grep -q 'previews?previewId=' "$FAKE_DIR/curl.log"
}

@test "GKE logs on: an unreadable deployment state only warns" {
  deployment streamsec-integration ACTIVE
  printf '{\n  "enable_gke_logs": {\n    "inputValue": "true"\n  }\n}\n' >"$FAKE_DIR/input-values"
  run_setup
  [ "$status" -eq 0 ]
  [[ "$output" == *"Could not read the state of deployment"* ]]
  grep -q 'previews?previewId=' "$FAKE_DIR/curl.log"
}

@test "GKE logs on: a deployment that runs the real-time module goes on, also from a moving ref" {
  deployment streamsec-integration ACTIVE $'google_logging_project_sink\tprojects/p1/sinks/streamsec-gke-audit-logs-pubsub-0a1b2c3d\tUNCHANGED\tRECONCILED'
  printf '{\n  "enable_gke_logs": {\n    "inputValue": "true"\n  }\n}\n' >"$FAKE_DIR/input-values"
  run_setup
  [ "$status" -eq 0 ]
  [[ "$output" != *"has the old GKE module"* && "$output" != *"Could not read the state"* ]]
  grep -q 'previews?previewId=' "$FAKE_DIR/curl.log"
}
