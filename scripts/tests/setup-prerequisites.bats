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
  [ ! -s "$FAKE_DIR/curl.log" ]
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
  called 'deployments list --project=p1 --location=us-central1 '
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
  [ ! -s "$FAKE_DIR/curl.log" ]
  refute_called ' delete '
}

@test "unreadable deployments stop the check and delete nothing" {
  exist topic:stream-security-events-topic
  echo "ERROR: (gcloud.infra-manager.deployments.list) PERMISSION_DENIED: denied" >"$FAKE_DIR/list-error"
  run_setup --cleanup-leftovers
  [ "$status" -eq 1 ]
  [[ "$output" == *PERMISSION_DENIED* ]]
  [ ! -s "$FAKE_DIR/curl.log" ]
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

@test "a resource whose existence can't be read stops the check" {
  exist "sa:$FN_SA"
  echo topic:stream-security-events-topic >"$FAKE_DIR/describe-errors"
  run_setup --cleanup-leftovers
  [ "$status" -eq 1 ]
  [[ "$output" == *PERMISSION_DENIED* ]]
  [[ "$output" == *"Could not tell whether these exist"* ]]
  refute_called ' delete '
  [ ! -s "$FAKE_DIR/curl.log" ]
}

@test "--yes doesn't delete leftovers that look in use" {
  exist topic:stream-security-events-topic "sa:$FN_SA"
  echo projects/p1/subscriptions/eventarc-sub >"$FAKE_DIR/subscriptions"
  run_setup --cleanup-leftovers
  [ "$status" -eq 1 ]
  [[ "$output" == *"Pub/Sub topic: stream-security-events-topic (subscriptions: 1)"* ]]
  [[ "$output" == *"--yes doesn't delete resources that look in use"* ]]
  refute_called ' delete '
}

@test "leftovers that look in use are deleted after an interactive yes" {
  exist topic:stream-security-events-topic
  echo projects/p1/subscriptions/eventarc-sub >"$FAKE_DIR/subscriptions"
  run bash -c 'echo y | bash "$0" --project-only --project-id p1 --region us-central1 --check-leftovers --cleanup-leftovers' "$SETUP"
  [ "$status" -eq 0 ]
  called 'pubsub topics delete stream-security-events-topic'
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
