#!/usr/bin/env bats
# deploy-gcs-file-collector.sh, against the fake gcloud and curl in tests/bin.

load helpers

DEPLOY="$BATS_TEST_DIRNAME/../deploy-gcs-file-collector.sh"
BUCKET=acme-github-audit
# The names modules/gcs-file-collector gives the collector of github-audit on $BUCKET (its tests
# expect the same literal)
SUFFIX=github-audit-a9abc0
FUNCTION="streamsec-$SUFFIX"
SA="ss-col-$SUFFIX@acme-logs.iam.gserviceaccount.com"
BUILD_SA="ss-bld-$SUFFIX@acme-logs.iam.gserviceaccount.com"
SECRET="streamsec-collector-token-$SUFFIX"

setup() {
  setup_fakes
  exist "bucket:$BUCKET"
  export STREAMSEC_COLLECTION_TOKEN=collection-token
}

deploy() {
  run bash "$DEPLOY" --project acme-logs --bucket "$BUCKET" --api-url https://acme.streamsec.io/ --yes "$@"
}

@test "deploys a function that receives every new object in the bucket, in the bucket's location" {
  printf 'US\t123456789\n' >"$FAKE_DIR/bucket-$BUCKET"
  deploy
  [ "$status" -eq 0 ]
  called "functions deploy $FUNCTION --gen2 --project acme-logs --region us-central1 --runtime python312 .*--entry-point collect"
  called "functions deploy .*--trigger-event-filters type=google.cloud.storage.object.v1.finalized --trigger-event-filters bucket=$BUCKET --trigger-location us "
  called "functions deploy .*--trigger-service-account $SA --retry "
  called "functions deploy .*--set-env-vars API_URL=https://acme.streamsec.io,API_URL_SUFFIX=github-audit --set-secrets API_TOKEN=$SECRET:latest"
  called "functions deploy .*--build-service-account projects/acme-logs/serviceAccounts/$BUILD_SA"
  [[ "$output" == *"Function $FUNCTION is ACTIVE"* ]]
}

@test "deploys the function_source of modules/gcs-file-collector next to it" {
  deploy
  [ "$status" -eq 0 ]
  called "functions deploy .*--source [^ ]*/modules/gcs-file-collector/function_source "
  [ ! -s "$FAKE_DIR/curl.log" ]
}

@test "outside a checkout, deploys the function_source of the release given with --ref" {
  mkdir -p "$BATS_TEST_TMPDIR/release/terraform-streamsec-google-integration-2.25.0/modules/gcs-file-collector/function_source"
  touch "$BATS_TEST_TMPDIR/release/terraform-streamsec-google-integration-2.25.0/modules/gcs-file-collector/function_source/main.py"
  tar -czf "$FAKE_DIR/source.tar.gz" -C "$BATS_TEST_TMPDIR/release" .
  cp "$DEPLOY" "$BATS_TEST_TMPDIR/deploy.sh"
  run bash "$BATS_TEST_TMPDIR/deploy.sh" --project acme-logs --bucket "$BUCKET" --api-url https://acme.streamsec.io --yes --ref v2.25.0
  [ "$status" -eq 0 ]
  grep -q "codeload.github.com/streamsec-terraform/terraform-streamsec-google-integration/tar.gz/v2.25.0" "$FAKE_DIR/curl.log"
  called "functions deploy .*--source [^ ]*/terraform-streamsec-google-integration-2.25.0/modules/gcs-file-collector/function_source "
}

@test "stops before any change when the release has no collector" {
  cp "$DEPLOY" "$BATS_TEST_TMPDIR/deploy.sh"
  run bash "$BATS_TEST_TMPDIR/deploy.sh" --project acme-logs --bucket "$BUCKET" --api-url https://acme.streamsec.io --yes --ref v1.0.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not download"* ]]
  refute_called "services enable|secrets (create|versions add)|add-iam-policy-binding|service-accounts create|functions deploy"
}

@test "stops before any change when the release is not a collector release" {
  mkdir -p "$BATS_TEST_TMPDIR/release/terraform-streamsec-google-integration-2.24.0/modules/gke"
  tar -czf "$FAKE_DIR/source.tar.gz" -C "$BATS_TEST_TMPDIR/release" .
  cp "$DEPLOY" "$BATS_TEST_TMPDIR/deploy.sh"
  run bash "$BATS_TEST_TMPDIR/deploy.sh" --project acme-logs --bucket "$BUCKET" --api-url https://acme.streamsec.io --yes --ref v2.24.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"has no modules/gcs-file-collector"* ]]
  refute_called "services enable|secrets (create|versions add)|add-iam-policy-binding|service-accounts create|functions deploy"
}

@test "keeps the collection token off the command line, in Secret Manager" {
  deploy
  [ "$status" -eq 0 ]
  called "secrets create $SECRET --project acme-logs --replication-policy automatic --data-file=-"
  [ "$(cat "$FAKE_DIR/secret-data-$SECRET")" = collection-token ]
  refute_called "collection-token"
  called "secrets add-iam-policy-binding $SECRET --project acme-logs --member serviceAccount:$SA --role roles/secretmanager.secretAccessor"
}

@test "a re-run stores the token given as a new version of the existing secret" {
  exist "secret:$SECRET" "sa:$SA" "sa:$BUILD_SA"
  export STREAMSEC_COLLECTION_TOKEN=new-token
  deploy
  [ "$status" -eq 0 ]
  refute_called "secrets create"
  refute_called "service-accounts create"
  called "secrets versions add $SECRET --project acme-logs --data-file=-"
  [ "$(cat "$FAKE_DIR/secret-data-$SECRET")" = new-token ]
}

@test "lets the collector read the bucket and receive its events, and Cloud Storage publish them" {
  deploy
  [ "$status" -eq 0 ]
  called "storage buckets add-iam-policy-binding gs://$BUCKET --member serviceAccount:$SA --role roles/storage.objectViewer"
  called "projects add-iam-policy-binding acme-logs --member serviceAccount:$SA --role roles/eventarc.eventReceiver"
  called "projects add-iam-policy-binding acme-logs --member serviceAccount:service-123456789@gs-project-accounts.iam.gserviceaccount.com --role roles/pubsub.publisher"
  called "projects add-iam-policy-binding acme-logs --member serviceAccount:$BUILD_SA --role roles/logging.logWriter --condition=None"
  called "projects add-iam-policy-binding acme-logs --member serviceAccount:$BUILD_SA --role roles/artifactregistry.writer --condition=None"
  refute_called "cloudbuild.builds.builder"
  called "functions add-invoker-policy-binding $FUNCTION --project acme-logs --region us-central1 --member serviceAccount:$SA"
  assert_called_before "storage buckets add-iam-policy-binding" "functions deploy"
}

@test "lets the builder touch only the buckets Cloud Functions builds from" {
  deploy
  [ "$status" -eq 0 ]
  local condition="expression=resource.type == 'storage.googleapis.com/Object' && ("
  condition+="resource.name.startsWith('projects/_/buckets/gcf-v2-sources-123456789-') || "
  condition+="resource.name.startsWith('projects/_/buckets/gcf-v2-uploads-123456789-') || "
  condition+="resource.name.startsWith('projects/_/buckets/run-sources-acme-logs-')),title=CollectorFunctionBuildObjects"
  grep -qF -- "--member serviceAccount:$BUILD_SA --role roles/storage.objectUser --condition=$condition --quiet" \
    "$FAKE_DIR/gcloud.log"
}

@test "a warning on the bucket's stderr is not read as its location" {
  printf '#!/usr/bin/env bash\necho "WARNING: a newer gcloud is available" >&2\nexec "%s/bin/gcloud" "$@"\n' \
    "$BATS_TEST_DIRNAME" >"$BATS_TEST_TMPDIR/gcloud"
  chmod +x "$BATS_TEST_TMPDIR/gcloud"
  PATH="$BATS_TEST_TMPDIR:$PATH" deploy
  [ "$status" -eq 0 ]
  called "functions deploy .*--trigger-location us-central1 "
}

@test "refuses a bucket in another project before changing anything" {
  printf 'US\t987654321\n' >"$FAKE_DIR/bucket-$BUCKET"
  deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"Bucket $BUCKET is not in project acme-logs"* ]]
  refute_called "services enable"
}

@test "refuses a bucket it cannot read before changing anything" {
  deploy --bucket missing-bucket
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cannot read bucket missing-bucket"* ]]
  refute_called "services enable"
}

@test "refuses a gs:// URL for the bucket" {
  run bash "$DEPLOY" --project acme-logs --bucket "gs://$BUCKET" --api-url https://acme.streamsec.io --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"--bucket must be a bucket name without gs://"* ]]
  [ ! -s "$FAKE_DIR/gcloud.log" ]
}

@test "a first deploy that fails while new permissions apply is retried once" {
  echo 1 >"$FAKE_DIR/deploy-failures"
  sleep() { :; }
  export -f sleep
  deploy
  [ "$status" -eq 0 ]
  [ "$(grep -c "functions deploy" "$FAKE_DIR/gcloud.log")" -eq 2 ]
}

@test "a failed deploy with existing service accounts is not retried" {
  exist "sa:$SA" "sa:$BUILD_SA"
  echo 1 >"$FAKE_DIR/deploy-failures"
  deploy
  [ "$status" -ne 0 ]
  [ "$(grep -c "functions deploy" "$FAKE_DIR/gcloud.log")" -eq 1 ]
}

@test "without --yes and no terminal, changes nothing" {
  run bash "$DEPLOY" --project acme-logs --bucket "$BUCKET" --api-url https://acme.streamsec.io </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"Nothing changed"* ]]
  refute_called "services enable"
}

@test "--uninstall removes the function, the secret, the service accounts and their bindings" {
  exist "function2:$FUNCTION" "secret:$SECRET" "sa:$SA" "sa:$BUILD_SA"
  run bash "$DEPLOY" --project acme-logs --bucket "$BUCKET" --uninstall --yes
  [ "$status" -eq 0 ]
  assert_mutations \
    "functions delete $FUNCTION --project acme-logs --region us-central1" \
    "secrets delete $SECRET --project acme-logs" \
    "storage buckets remove-iam-policy-binding gs://$BUCKET --member serviceAccount:$SA --role roles/storage.objectViewer" \
    "projects remove-iam-policy-binding acme-logs --member serviceAccount:$SA --role roles/eventarc.eventReceiver" \
    "service-accounts delete $SA" \
    "projects remove-iam-policy-binding acme-logs --member serviceAccount:$BUILD_SA --role roles/logging.logWriter --all" \
    "projects remove-iam-policy-binding acme-logs --member serviceAccount:$BUILD_SA --role roles/artifactregistry.writer --all" \
    "projects remove-iam-policy-binding acme-logs --member serviceAccount:$BUILD_SA --role roles/storage.objectUser --all" \
    "service-accounts delete $BUILD_SA"
  [ "$(cat "$FAKE_DIR/existing")" = "bucket:$BUCKET" ]
}

@test "--uninstall reports a removal that fails" {
  exist "sa:$SA" "sa:$BUILD_SA"
  echo "sa:$SA" >"$FAKE_DIR/fail-delete"
  run bash "$DEPLOY" --project acme-logs --bucket "$BUCKET" --uninstall --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED_PRECONDITION: in use"* ]]
}
