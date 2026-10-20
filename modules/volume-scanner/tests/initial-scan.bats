#!/usr/bin/env bats
# initial-scan.sh, against the fake curl in tests/bin.

SCRIPT="$BATS_TEST_DIRNAME/../initial-scan.sh"
JOB=https://run.googleapis.com/v2/projects/p1/locations/us-central1/jobs/streamsec-volume-scanner-orchestrator
TOKEN=ya29.test-token

setup() {
  export FAKE_DIR="$BATS_TEST_TMPDIR/fake"
  mkdir -p "$FAKE_DIR"
  : >"$FAKE_DIR/curl.log"
  : >"$FAKE_DIR/curl.stdin"
  echo "{\"name\":\"projects/p1/locations/us-central1/jobs/streamsec-volume-scanner-orchestrator\",\"executionCount\":0}" >"$FAKE_DIR/job.json"
  export PATH="$BATS_TEST_DIRNAME/bin:$PATH"
  export RUN_JOB_URL="$JOB" RUN_ACCESS_TOKEN="$TOKEN"
}

last_execution() {
  printf '{"name":"%s","latestCreatedExecution":{"name":"%s/executions/x","completionStatus":"%s"}}\n' \
    "$JOB" "$JOB" "$1" >"$FAKE_DIR/job.json"
}

started() { grep -q -- "-X POST .*$JOB:run" "$FAKE_DIR/curl.log"; }

@test "a new job is started once" {
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c ':run' "$FAKE_DIR/curl.log")" -eq 1 ]
  started
  # The job is read before it is started.
  head -n1 "$FAKE_DIR/curl.log" | grep -q -- "$JOB\$"
}

@test "a run in progress is left alone" {
  last_execution EXECUTION_RUNNING
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  ! started
}

@test "a pending run is left alone" {
  last_execution EXECUTION_PENDING
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  ! started
}

@test "a job whose last run finished is started" {
  last_execution EXECUTION_SUCCEEDED
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  started
}

@test "a job that can't be read is not started, and the apply still succeeds" {
  touch "$FAKE_DIR/get-fail"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  ! started
}

@test "a failed start doesn't fail the apply" {
  touch "$FAKE_DIR/run-fail"
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  started
}

@test "HTTP errors fail each call, and no call can hang the apply" {
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c -E -- '-[a-zA-Z]*f[a-zA-Z]* .*--max-time [0-9]+' "$FAKE_DIR/curl.log")" -eq 2 ]
}

@test "the token reaches curl on stdin, never on its command line" {
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q "$TOKEN" "$FAKE_DIR/curl.log"
  [ "$(grep -c "^header = \"Authorization: Bearer $TOKEN\"\$" "$FAKE_DIR/curl.stdin")" -eq 2 ]
}
