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
  [[ "$output" == *"cleanup-abandoned-deployment.sh --project-id p1 --region us-central1 --only topic,function-sa"* ]]
  [[ "$output" == *"--cleanup-leftovers"* ]]
  [[ "$output" != *"Step 6/6"* ]]
  [ ! -s "$FAKE_DIR/curl.log" ]
  refute_called ' delete '
}

@test "(c) resources in the deployment's state are a re-apply, not leftovers" {
  exist topic:stream-security-events-topic "sa:$FN_SA"
  deployment ACTIVE "$TOPIC_ROW"$'\tUNCHANGED\tRECONCILED' "$FN_SA_ROW"$'\tUNCHANGED\tRECONCILED'
  run_setup
  [ "$status" -eq 0 ]
  [[ "$output" == *"No leftovers"* ]]
  [[ "$output" == *"Step 6/6"* ]]
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
  deployment ACTIVE "$TOPIC_ROW"$'\tUNCHANGED\tRECONCILED'
  run_setup --cleanup-leftovers
  [ "$status" -eq 0 ]
  called "service-accounts delete $FN_SA"
  refute_called 'pubsub topics delete'
}

@test "the 409 rows of a failed apply (no id) don't make a leftover owned" {
  exist topic:stream-security-events-topic "sa:$FN_SA" "sa:$SA"
  deployment FAILED $'google_pubsub_topic\t\tCREATE\tFAILED' $'google_service_account\t\tCREATE\tFAILED' \
    $'google_service_account\tprojects/p1/serviceAccounts/'"$SA"$'\tCREATE\tRECONCILED'
  run_setup
  [ "$status" -eq 1 ]
  [[ "$output" == *"--only topic,function-sa"* ]]
}

@test "a resource the latest revision deleted is not owned" {
  exist topic:stream-security-events-topic
  deployment ACTIVE "$TOPIC_ROW"$'\tDELETE\tRECONCILED'
  run_setup
  [ "$status" -eq 1 ]
  [[ "$output" == *"--only topic"* ]]
}

@test "a deployment mid-apply stops the check rather than guess" {
  exist topic:stream-security-events-topic
  deployment UPDATING
  run_setup --cleanup-leftovers
  [ "$status" -eq 1 ]
  [[ "$output" == *UPDATING* ]]
  [ ! -s "$FAKE_DIR/curl.log" ]
  refute_called ' delete '
}

@test "an unreadable deployment stops the check and deletes nothing" {
  exist topic:stream-security-events-topic
  echo "ERROR: (gcloud.infra-manager.deployments.describe) PERMISSION_DENIED: denied" >"$FAKE_DIR/describe-error"
  run_setup --cleanup-leftovers
  [ "$status" -eq 1 ]
  [[ "$output" == *PERMISSION_DENIED* ]]
  [ ! -s "$FAKE_DIR/curl.log" ]
  refute_called ' delete '
}

@test "other deployments in the project are named in the warning" {
  exist topic:stream-security-events-topic
  printf '%s\t%s\n' other-integration europe-west1 streamsec-integration us-central1 >"$FAKE_DIR/deployments"
  run_setup
  [ "$status" -eq 1 ]
  [[ "$output" == *"other-integration (europe-west1)"* ]]
  [[ "$output" != *"streamsec-integration (us-central1)"* ]]
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
  [[ "$output" == *"--region us-central1 --org-id 123 --only org-sink"* ]]
  refute_called 'sinks describe stream-security-events-sink --project='
}

@test "the regional secret is checked through the regional endpoint" {
  exist regional-secret:stream-security
  run_check --project-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"Regional secret: stream-security (us-central1)"* ]]
  called 'secrets describe stream-security --location=us-central1 --project=p1 \[endpoint=https://secretmanager.us-central1.rep.googleapis.com/\]'
}
