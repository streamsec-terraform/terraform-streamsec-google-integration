# Shared setup for the script tests: the fake gcloud and curl in tests/bin go
# first on PATH, and $FAKE_DIR holds their state and call logs.

setup_fakes() {
  export FAKE_DIR="$BATS_TEST_TMPDIR/fake"
  mkdir -p "$FAKE_DIR"
  : >"$FAKE_DIR/existing"
  : >"$FAKE_DIR/gcloud.log"
  : >"$FAKE_DIR/curl.log"
  export PATH="$BATS_TEST_DIRNAME/bin:$PATH"
}

# exist topic:NAME sa:EMAIL ... (kinds as in tests/bin/gcloud)
exist() { printf '%s\n' "$@" >>"$FAKE_DIR/existing"; }

# deployment STATE [ROW...]: a deployment whose latest revision lists ROWs of
# "<terraform type>\t<id>\t<intent>\t<state>".
deployment() {
  printf 'projects/p1/locations/us-central1/deployments/streamsec-integration/revisions/r-0\t%s\n' "$1" >"$FAKE_DIR/deployment"
  shift
  printf '%s\n' "$@" >"$FAKE_DIR/resources"
}

called() {
  grep -qE "$1" "$FAKE_DIR/gcloud.log" || { echo "no call matching '$1' in:"; cat "$FAKE_DIR/gcloud.log"; return 1; }
}

refute_called() {
  ! grep -qE "$1" "$FAKE_DIR/gcloud.log" || { echo "unexpected call(s):"; grep -E "$1" "$FAKE_DIR/gcloud.log"; return 1; }
}

# The first call matching $1 comes before the first matching $2.
assert_called_before() {
  local a b
  a=$(grep -n -m1 -E "$1" "$FAKE_DIR/gcloud.log" | cut -d: -f1)
  b=$(grep -n -m1 -E "$2" "$FAKE_DIR/gcloud.log" | cut -d: -f1)
  [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]] || {
    echo "expected '$1' (line ${a:-none}) before '$2' (line ${b:-none}) in:"
    cat "$FAKE_DIR/gcloud.log"
    return 1
  }
}

# The mutating calls (deletes, binding removals) match the patterns, in this order and no others.
assert_mutations() {
  local calls=() line i=0
  while IFS= read -r line; do calls+=("$line"); done < <(grep -E ' (delete|remove-iam-policy-binding) ' "$FAKE_DIR/gcloud.log")
  if [[ ${#calls[@]} -ne $# ]]; then
    echo "expected $# mutating calls, got ${#calls[@]}:"; printf '  %s\n' "${calls[@]}"; return 1
  fi
  for pattern in "$@"; do
    [[ "${calls[$i]}" =~ $pattern ]] || { echo "call $i '${calls[$i]}' does not match '$pattern'"; return 1; }
    i=$((i + 1))
  done
}

# Line number of the first output line containing $1 ($output comes from bats' run).
# shellcheck disable=SC2154
line_of() { grep -n -m1 -F -- "$1" <<<"$output" | cut -d: -f1; }
