#!/bin/sh
# Starts one run of the orchestrator job at $RUN_JOB_URL unless one is in
# progress. Always exits 0: the schedule is the fallback for a run that can't start.
# The token reaches curl on stdin, so it stays off the process command line.
set -u

api() {
  printf 'header = "Authorization: Bearer %s"\n' "$RUN_ACCESS_TOKEN" | curl -fsS --max-time 30 -K - "$@"
}

if ! job=$(api "$RUN_JOB_URL"); then
  echo "initial scan: could not read the job; the scheduled run will scan"
  exit 0
fi

case "$job" in
  *'"EXECUTION_RUNNING"'* | *'"EXECUTION_PENDING"'*)
    echo "initial scan: a run is already in progress"
    exit 0
    ;;
esac

if api -X POST -H "Content-Type: application/json" -d '{}' -o /dev/null "$RUN_JOB_URL:run"; then
  echo "initial scan: started"
else
  echo "initial scan: could not start it; the scheduled run will scan"
fi
exit 0
