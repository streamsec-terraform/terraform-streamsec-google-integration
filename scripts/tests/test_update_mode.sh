#!/usr/bin/env bash
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/setup-prerequisites.sh"
DEPLOYMENT_PATH="projects/test-proj/locations/us-central1/deployments/streamsec-integration"
FAILURES=0

make_stubs() {
  local dir="$1"
  cat > "$dir/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "gcloud $*" >> "$STUB_LOG"
case "$*" in
  "infra-manager deployments describe"*) [[ "$EXISTING" == true ]] && exit 0 || exit 1 ;;
  "infra-manager previews describe"*"value(state)"*) echo "SUCCEEDED" ;;
  "auth print-access-token"*) echo "test-token" ;;
esac
exit 0
STUB
  cat > "$dir/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) printf '%s' "$2" > "$CURL_BODY"; shift 2 ;;
    -w) printf '200'; shift 2 ;;
    *) shift ;;
  esac
done
STUB
  chmod +x "$dir/gcloud" "$dir/curl"
}

run_case() {
  local name="$1" existing="$2"; shift 2
  local dir; dir=$(mktemp -d)
  make_stubs "$dir"
  export STUB_LOG="$dir/calls.log" CURL_BODY="$dir/body.json" EXISTING="$existing"
  : > "$STUB_LOG"; : > "$CURL_BODY"
  OUTPUT=$(PATH="$dir:$PATH" bash "$SCRIPT" \
    --project-id test-proj --org-id 123456789 --region us-central1 \
    --streamsec-host tenant.streamsec.io --workspace-id ws --api-token tok \
    --git-ref v9.9.9 --start-from-step 6 --skip-permission-check --yes "$@" 2>&1)
  CALLS=$(cat "$STUB_LOG")
  BODY=$(cat "$CURL_BODY")
  CASE="$name"
}

check() {
  if eval "$1"; then
    echo "  ok: $2"
  else
    echo "  FAIL [$CASE]: $2"
    FAILURES=$((FAILURES + 1))
  fi
}

run_case "org mode, existing deployment" true
check '[[ "$CALLS" == *"previews create"*"--deployment=$DEPLOYMENT_PATH"* ]]' "preview targets the existing deployment"
check '[[ "$OUTPUT" == *"update the existing deployment"* && "$OUTPUT" == *"Git ref to v9.9.9"* ]]' "prints update instructions"
check '[[ "$OUTPUT" != *"create the deployment"* ]]' "does not tell the customer to create a new deployment"

run_case "org mode, new deployment" false
check '[[ "$CALLS" == *"previews create"* && "$CALLS" != *"--deployment="* ]]' "preview is a new deployment"
check '[[ "$OUTPUT" == *"create the deployment"* ]]' "prints create instructions"

run_case "single-project mode, existing deployment" true --single-project
check '[[ "$BODY" == *"\"deployment\": \"$DEPLOYMENT_PATH\""* ]]' "REST preview targets the existing deployment"
check '[[ "$OUTPUT" == *"update the existing deployment"* ]]' "prints update instructions"

run_case "single-project mode, new deployment" false --single-project
check '[[ -n "$BODY" && "$BODY" != *"\"deployment\""* ]]' "REST preview is a new deployment"

if [[ $FAILURES -gt 0 ]]; then
  echo "$FAILURES check(s) failed"
  exit 1
fi
echo "All checks passed"
