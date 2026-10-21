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
  "infra-manager deployments describe"*)
    case "$EXISTING" in
      true)
        if [[ "$*" == *inputValues* ]]; then
          cat <<'JSON'
{
  "terraformBlueprint": {
    "inputValues": {
      "include_projects": {
        "inputValue": ["test-proj"]
      },
      "org_level_sink": {
        "inputValue": false
      },
      "sa_account_id": {
        "inputValue": "custom-sa"
      },
      "sa_description": {
        "inputValue": "Scanner } team \"x\""
      }
    }
  }
}
JSON
        fi
        rev="r-1"; [[ -s "$PATCH_BODY" && "${NEW_REVISION:-true}" == true ]] && rev="r-2"
        if [[ -n "${CHANGED_SINCE_PREVIEW:-}" && "$*" == *"value(latestRevision)"* ]]; then
          [[ -f "$STUB_LOG.rev" ]] && rev="r-9"; touch "$STUB_LOG.rev"
        fi
        [[ "$*" == *"value(state,latestRevision)"* ]] && echo "${STATE:-ACTIVE} $rev"
        [[ "$*" == *"value(latestRevision)"* ]] && echo "$rev"
        exit 0 ;;
      false) echo "ERROR: (gcloud.infra-manager.deployments.describe) NOT_FOUND: Resource not found" >&2; exit 1 ;;
      *) echo "ERROR: (gcloud.infra-manager.deployments.describe) PERMISSION_DENIED: Permission denied" >&2; exit 1 ;;
    esac ;;
  "infra-manager previews describe"*"value(state)"*) echo "SUCCEEDED" ;;
  "auth print-access-token"*) echo "test-token" ;;
esac
exit 0
STUB
  cat > "$dir/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
out="$CURL_BODY"; code=200; [[ " $* " == *" PATCH "* ]] && { out="$PATCH_BODY"; code="${PATCH_HTTP:-200}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-binary) [[ "$2" == @- ]] && cat > "$out"; shift 2 ;;
    -w) printf '%s' "$code"; shift 2 ;;
    *) shift ;;
  esac
done
STUB
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/sleep"
  chmod +x "$dir/gcloud" "$dir/curl" "$dir/sleep"
}

run_case() {
  local name="$1" existing="$2"; shift 2
  local dir; dir=$(mktemp -d)
  make_stubs "$dir"
  export STUB_LOG="$dir/calls.log" CURL_BODY="$dir/body.json" PATCH_BODY="$dir/patch.json" EXISTING="$existing"
  : > "$STUB_LOG"; : > "$CURL_BODY"; : > "$PATCH_BODY"
  OUTPUT=$(printf '%s' "${ANSWERS:-}" | PATH="$dir:$PATH" bash "$SCRIPT" \
    --project-id test-proj --org-id 123456789 --region us-central1 \
    --streamsec-host tenant.streamsec.io --workspace-id ws --api-token tok \
    --git-ref v9.9.9 --start-from-step 6 --skip-permission-check --skip-leftover-check "$@" 2>&1)
  CALLS=$(cat "$STUB_LOG")
  BODY=$(cat "$CURL_BODY")
  PATCH=$(cat "$PATCH_BODY")
  CASE="$name"
  rm -rf "$dir"
}

check() {
  if eval "$1"; then
    echo "  ok: $2"
  else
    echo "  FAIL [$CASE]: $2"
    FAILURES=$((FAILURES + 1))
  fi
}

run_case "org mode, existing deployment" true --yes
check '[[ "$BODY" == *"\"deployment\": \"$DEPLOYMENT_PATH\""* ]]' "preview targets the existing deployment"
check '[[ "$BODY" == *"\"custom-sa\""* && "$BODY" == *"[\"test-proj\"]"* ]]' "preview keeps the deployment's own inputs"
check '[[ "$BODY" == *"Scanner } team \\\"x\\\""* ]]' "keeps an input whose string contains braces and quotes"
check '[[ "$BODY" != *"streamsec_secret_name"* ]]' "preview does not use the script's default inputs"
check 'python3 -c "import json,sys; json.load(sys.stdin)" <<< "$BODY"' "request body is valid JSON"
check '[[ "$(grep "^curl" <<< "$CALLS")" == curl* && "$(grep "^curl" <<< "$CALLS")" != *custom-sa* ]]' "request body is not on the curl command line"
check '[[ "$CALLS" == *"-X PATCH https://config.googleapis.com/v1/$DEPLOYMENT_PATH?updateMask=terraformBlueprint"* ]]' "applies the update to the existing deployment"
check '[[ "$PATCH" == *"\"ref\": \"v9.9.9\""* && "$PATCH" == *"\"custom-sa\""* ]]' "the update uses the new ref and the deployment's own inputs"
check 'python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"terraformBlueprint\"][\"inputValues\"][\"org_level_sink\"][\"inputValue\"] is False" <<< "$PATCH"' "the update keeps an input set to false"
check '[[ "$OUTPUT" == *"updated to v9.9.9"* ]]' "reports the applied update"
check '[[ "$PATCH" != *serviceAccount* && "$PATCH" != *labels* ]]' "the update changes only the blueprint"
check '[[ "$OUTPUT" != *"create the deployment"* ]]' "does not tell the customer to create a new deployment"

run_case "org mode, new deployment" false --yes
check '[[ "$CALLS" == *"previews create"* && -z "$BODY" ]]' "preview is a new deployment"
check '[[ "$OUTPUT" == *"create the deployment"* ]]' "prints create instructions"

run_case "single-project mode, existing deployment" true --single-project --yes
check '[[ "$BODY" == *"\"deployment\": \"$DEPLOYMENT_PATH\""* ]]' "REST preview targets the existing deployment"
check '[[ "$BODY" == *"\"custom-sa\""* ]]' "REST preview keeps the deployment's own inputs"
check 'python3 -c "import json,sys; json.load(sys.stdin)" <<< "$BODY"' "request body is valid JSON"
check 'python3 -c "import json,sys; json.load(sys.stdin)" <<< "$PATCH" && [[ "$PATCH" == *"\"custom-sa\""* ]]' "applies the update with the deployment's own inputs"

run_case "single-project mode, new deployment" false --single-project --yes
check '[[ -n "$BODY" && "$BODY" != *"\"deployment\""* ]]' "REST preview is a new deployment"
check 'python3 -c "import json,sys; json.load(sys.stdin)" <<< "$BODY"' "request body is valid JSON"

run_case "describe fails for another reason" denied --yes
check '[[ "$OUTPUT" == *"Could not check whether deployment"* && "$OUTPUT" == *"PERMISSION_DENIED"* ]]' "reports the describe error"
check '[[ "$CALLS" != *"previews create"* ]]' "does not create any preview"

ANSWERS=$'y\nn\n' run_case "existing deployment, update declined" true
check '[[ -n "$BODY" && -z "$PATCH" && "$CALLS" != *PATCH* ]]' "previews but does not apply"
check '[[ "$OUTPUT" == *"Update not applied"* ]]' "says the update was not applied"

STATE=FAILED run_case "existing deployment, update fails" true --yes
check '[[ "$OUTPUT" == *"The update of"*"failed"* && "$OUTPUT" != *"updated to v9.9.9"* ]]' "reports a failed update"

PATCH_HTTP=400 run_case "existing deployment, update request rejected" true --yes
check '[[ "$OUTPUT" == *"REST API returned HTTP 400"* && "$OUTPUT" != *"updated to v9.9.9"* ]]' "reports a rejected update request"

CHANGED_SINCE_PREVIEW=1 run_case "existing deployment, changed since the preview" true --yes
check '[[ "$OUTPUT" == *"changed since the preview"* && -z "$PATCH" ]]' "does not apply over a newer revision"

NEW_REVISION=false run_case "existing deployment, no new revision" true --yes
check '[[ "$OUTPUT" == *"still running"* && "$OUTPUT" != *"updated to v9.9.9"* ]]' "does not report success without a new revision"

if [[ $FAILURES -gt 0 ]]; then
  echo "$FAILURES check(s) failed"
  exit 1
fi
echo "All checks passed"
