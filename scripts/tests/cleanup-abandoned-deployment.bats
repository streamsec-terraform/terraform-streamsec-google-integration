#!/usr/bin/env bats
# cleanup-abandoned-deployment.sh, against the fake gcloud in tests/bin.

load helpers

CLEANUP="$BATS_TEST_DIRNAME/../cleanup-abandoned-deployment.sh"
FN_SA=stream-security-function-sa@p1.iam.gserviceaccount.com
SA=stream-security@p1.iam.gserviceaccount.com
IM_SA=StreamSecurityInfraManagerSa@p1.iam.gserviceaccount.com

setup() { setup_fakes; }

@test "a full cleanup deletes everything, each resource after what depends on it" {
  exist function2:stream-security-events-function \
    project-sink:stream-security-events-sink topic:stream-security-events-topic \
    secret:stream-security-collection-token regional-secret:stream-security \
    "sa:$FN_SA" "sa:$SA" "sa:$IM_SA" \
    project-role:StreamSecurityInfraManagerOpsRole project-role:StreamSecurityInfraManagerProjectRole
  printf 'serviceAccount:%s\t%s\n' "$IM_SA" projects/p1/roles/StreamSecurityInfraManagerOpsRole \
    "$IM_SA" projects/p1/roles/StreamSecurityInfraManagerProjectRole "$IM_SA" roles/config.agent >"$FAKE_DIR/project-iam"
  run bash "$CLEANUP" --project-id p1 --region us-central1 --yes
  [ "$status" -eq 0 ]
  assert_mutations \
    'functions delete stream-security-events-function .*--gen2' \
    'logging sinks delete stream-security-events-sink --project=p1' \
    'pubsub topics delete stream-security-events-topic' \
    'secrets delete stream-security-collection-token --project=p1' \
    'secrets delete stream-security .*--location=us-central1.*\[endpoint=https://secretmanager.us-central1.rep.googleapis.com/\]' \
    "service-accounts delete $FN_SA" \
    "service-accounts delete $SA" \
    'projects remove-iam-policy-binding p1 .*roles/StreamSecurityInfraManagerOpsRole' \
    'projects remove-iam-policy-binding p1 .*roles/StreamSecurityInfraManagerProjectRole' \
    'projects remove-iam-policy-binding p1 .*roles/config.agent' \
    "service-accounts delete $IM_SA" \
    'roles delete StreamSecurityInfraManagerOpsRole --project=p1' \
    'roles delete StreamSecurityInfraManagerProjectRole --project=p1'
  [ ! -s "$FAKE_DIR/existing" ]
}

@test "with an org ID, the org sink and the SA's org bindings go before the SA" {
  exist org-sink:stream-security-events-sink "sa:$SA"
  printf 'serviceAccount:%s\t%s\n' "$SA" roles/viewer "$SA" roles/iam.securityReviewer >"$FAKE_DIR/org-iam"
  run bash "$CLEANUP" --project-id p1 --region us-central1 --org-id 123 --yes
  [ "$status" -eq 0 ]
  assert_mutations \
    'organizations remove-iam-policy-binding 123 .*roles/viewer' \
    'organizations remove-iam-policy-binding 123 .*roles/iam.securityReviewer' \
    'logging sinks delete stream-security-events-sink --organization=123' \
    "service-accounts delete $SA"
}

@test "--only deletes just those kinds and leaves the runner SA and roles alone" {
  exist topic:stream-security-events-topic "sa:$FN_SA" "sa:$SA" "sa:$IM_SA" \
    project-role:StreamSecurityInfraManagerProjectRole
  run bash "$CLEANUP" --project-id p1 --region us-central1 --only topic,function-sa --yes
  [ "$status" -eq 0 ]
  assert_mutations 'pubsub topics delete stream-security-events-topic' "service-accounts delete $FN_SA"
  refute_called 'StreamSecurityInfraManager|get-iam-policy'
}

@test "--only rejects an unknown kind before touching anything" {
  run bash "$CLEANUP" --project-id p1 --region us-central1 --only topic,bogus --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *bogus* ]]
  [ ! -s "$FAKE_DIR/gcloud.log" ]
}

@test "--only org-sink needs --org-id" {
  run bash "$CLEANUP" --project-id p1 --region us-central1 --only org-sink --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"--org-id"* ]]
  [ ! -s "$FAKE_DIR/gcloud.log" ]
}

@test "an empty --only is rejected, not read as a full cleanup" {
  exist "sa:$IM_SA" project-role:StreamSecurityInfraManagerProjectRole
  run bash "$CLEANUP" --project-id p1 --region us-central1 --only "" --yes
  [ "$status" -ne 0 ]
  refute_called ' delete '
}

@test "--only tolerates spaces after the commas" {
  exist topic:stream-security-events-topic "sa:$FN_SA"
  run bash "$CLEANUP" --project-id p1 --region us-central1 --only "topic, function-sa" --yes
  [ "$status" -eq 0 ]
  assert_mutations 'pubsub topics delete stream-security-events-topic' "service-accounts delete $FN_SA"
}

@test "a resource whose existence can't be read is reported, not deleted" {
  exist topic:stream-security-events-topic
  echo topic:stream-security-events-topic >"$FAKE_DIR/describe-errors"
  run bash "$CLEANUP" --project-id p1 --region us-central1 --only topic --yes
  [[ "$output" == *"Could not check: Pub/Sub topic: stream-security-events-topic"* ]]
  refute_called ' delete '
}
