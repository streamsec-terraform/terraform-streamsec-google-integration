"""Simulation tests for the vertex-ai-logging collector's lookback sweep.

Stubs out GCP + requests so main.py can be imported and driven through real poll sequences.
The fake BigQuery models the thing that actually matters: a row has an event time
(logging_time) AND a separate visibility time, so late arrival can be reproduced exactly.
"""
import io, json, sys, types
from datetime import datetime, timedelta, timezone

# ---------------------------------------------------------------- fake GCP + requests

class FakeBlob:
    def __init__(self, store, name):
        self.store, self.name = store, name
    @property
    def generation(self):
        return self.store.get(self.name, (None, 0))[1]
    def exists(self):
        return self.name in self.store
    def reload(self):
        pass
    def download_as_text(self):
        return self.store[self.name][0]
    def upload_from_string(self, data, content_type=None, if_generation_match=None):
        current = self.store.get(self.name, (None, 0))[1]
        if if_generation_match is not None and if_generation_match != current:
            raise RuntimeError(f"PreconditionFailed: generation {if_generation_match} != {current}")
        self.store[self.name] = (data, current + 1)

class FakeBucket:
    def __init__(self, store): self.store = store
    def blob(self, name): return FakeBlob(self.store, name)

class FakeStorageClient:
    store = {}
    def __init__(self, project=None): pass
    def bucket(self, name): return FakeBucket(FakeStorageClient.store)

class FakeQueryJob:
    def __init__(self, rows): self.rows = rows
    def __iter__(self): return iter(self.rows)

class FakeBigQueryClient:
    table = []          # list of dicts with logging_time, request_id, visible_at
    now = None          # simulated wall clock
    max_rows = None     # set from main.MAX_ROWS_PER_POLL at call time
    def __init__(self, project=None): pass
    def query(self, query, job_config=None):
        """Mirror the real two-range query: forward past the cursor + a bounded sweep behind it.

        Each range gets its OWN limit, which is the property under test — a single shared limit
        lets the sweep starve forward progress.
        """
        p = {q.name: q.value for q in job_config.query_parameters}
        as_ts = lambda v: v if isinstance(v, datetime) else datetime.fromisoformat(str(v))
        floor_ts, wm_ts = as_ts(p["floor"]), as_ts(p["watermark"])
        last_id, limit = p["last_request_id"], p["max_rows"]
        key = lambda r: (r["logging_time"], str(r["request_id"] or ""))

        visible = [r for r in FakeBigQueryClient.table
                   if r["visible_at"] <= FakeBigQueryClient.now]

        forward = [r for r in visible
                   if r["logging_time"] > wm_ts
                   or (r["logging_time"] == wm_ts and str(r["request_id"] or "") > last_id)]
        forward.sort(key=key)
        forward = forward[:limit]

        sweep = [r for r in visible
                 if r["logging_time"] > floor_ts
                 and (r["logging_time"] < wm_ts
                      or (r["logging_time"] == wm_ts and str(r["request_id"] or "") <= last_id))]
        sweep.sort(key=key, reverse=True)
        sweep = sweep[:limit]

        rows = forward + sweep
        return FakeQueryJob([{k: v for k, v in r.items() if k != "visible_at"} for r in rows])

class FakeSession:
    fail_keys = set()
    sent = []
    def __init__(self): self.headers = {}
    class _H(dict):
        def update(self, *a, **k): dict.update(self, *a, **k)
    def post(self, url, json=None, timeout=None):
        key = json.get("requestId")
        FakeSession.sent.append(key)
        resp = types.SimpleNamespace()
        if key in FakeSession.fail_keys:
            resp.raise_for_status = lambda: (_ for _ in ()).throw(RuntimeError(f"500 for {key}"))
        else:
            resp.raise_for_status = lambda: None
        return resp

def install_fakes():
    ff = types.ModuleType("functions_framework"); ff.http = lambda fn: fn
    sys.modules["functions_framework"] = ff

    rq = types.ModuleType("requests"); rq.Session = FakeSession
    sys.modules["requests"] = rq

    bq = types.ModuleType("bigquery")
    bq.Client = FakeBigQueryClient
    class QJC:
        def __init__(self, query_parameters=None): self.query_parameters = query_parameters or []
    class SQP:
        def __init__(self, name, type_, value): self.name, self.value = name, value
    bq.QueryJobConfig, bq.ScalarQueryParameter = QJC, SQP

    sm = types.ModuleType("secretmanager")
    class SMC:
        def __init__(self, client_options=None): pass
        def access_secret_version(self, request=None):
            return types.SimpleNamespace(payload=types.SimpleNamespace(data=b"tok"))
    sm.SecretManagerServiceClient = SMC

    st = types.ModuleType("storage"); st.Client = FakeStorageClient

    gc = types.ModuleType("google.cloud")
    gc.bigquery, gc.secretmanager, gc.storage = bq, sm, st
    google = types.ModuleType("google"); google.cloud = gc
    sys.modules["google"], sys.modules["google.cloud"] = google, gc
    sys.modules["google.cloud.bigquery"] = bq
    sys.modules["google.cloud.secretmanager"] = sm
    sys.modules["google.cloud.storage"] = st

# ---------------------------------------------------------------- harness

import os
os.environ.update({
    "GCP_PROJECT_ID": "p", "BIGQUERY_DATASET": "d", "BIGQUERY_TABLE": "t",
    "API_URL": "https://x", "STATE_BUCKET": "b", "SECRET_NAME": "s",
    "LOOKBACK_MINUTES": "15", "BATCH_SIZE": "4",
})
install_fakes()

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "function_source"))
import main

# Tag each audit log with its request id so the fake session can identify it.
_orig = main.row_to_gcp_audit_log
def tagged(row):
    out = _orig(row)
    out["requestId"] = row.get("request_id")
    return out
main.row_to_gcp_audit_log = tagged

T0 = datetime(2026, 8, 13, 10, 0, 0, tzinfo=timezone.utc)
def ts(**kw): return T0 + timedelta(**kw)

def reset(rows, lookback=15, max_rows=10000):
    FakeStorageClient.store.clear()
    FakeBigQueryClient.table = rows
    main.LOOKBACK_MINUTES = lookback
    main.MAX_ROWS_PER_POLL = max_rows
    FakeSession.sent, FakeSession.fail_keys = [], set()

def poll(now):
    FakeBigQueryClient.now = now
    FakeSession.sent = []
    body, code = main.handler(None)
    return body, code, list(FakeSession.sent)

def row(rid, event_min, visible_min=None):
    return {"logging_time": ts(minutes=event_min), "request_id": rid,
            "visible_at": ts(minutes=visible_min if visible_min is not None else event_min),
            "model": "m", "endpoint": "", "deployed_model_id": "", "model_version": "",
            "api_method": "predict", "full_request": "{}", "full_response": "{}", "metadata": {}}

results = []
def check(name, cond, detail=""):
    results.append((name, cond, detail))
    print(("PASS  " if cond else "FAIL  ") + name + (f"   [{detail}]" if detail and not cond else ""))

# ---------------------------------------------------------------- 1. THE BUG: late arrival

reset([row("A", 0), row("B", 1), row("C", 0.5, visible_min=6)])
b1, c1, s1 = poll(ts(minutes=5))
check("late-arrival: first poll sends visible rows", sorted(s1) == ["A", "B"], str(s1))
b2, c2, s2 = poll(ts(minutes=10))
check("late-arrival: late row IS recovered by the sweep", s2 == ["C"], str(s2))
check("late-arrival: already-delivered rows not re-sent", "A" not in s2 and "B" not in s2, str(s2))
check("late-arrival: watermark not dragged back", b2["new_watermark"] == b1["new_watermark"],
      f'{b1["new_watermark"]} -> {b2["new_watermark"]}')
check("late-arrival: catch-up-only poll still returns 200", c2 == 200, str(c2))

# same scenario with the sweep disabled reproduces the original data loss
reset([row("A", 0), row("B", 1), row("C", 0.5, visible_min=6)], lookback=0)
poll(ts(minutes=5))
_, _, s_no = poll(ts(minutes=10))
check("control: lookback=0 still drops the late row", s_no == [], str(s_no))

# ---------------------------------------------------------------- 2. tie at the row limit

reset([row("r1", 0), row("r2", 0), row("r3", 0), row("r4", 0)], max_rows=2)
ba, _, sa = poll(ts(minutes=5))
check("tie-split: first poll capped at the limit", len(sa) == 2, str(sa))
check("tie-split: cursor records the request_id it stopped at",
      ba["new_last_request_id"] == "r2", str(ba["new_last_request_id"]))
bb, _, sb = poll(ts(minutes=6))
check("tie-split: remainder recovered next poll", sorted(sa + sb) == ["r1", "r2", "r3", "r4"],
      str(sa + sb))
check("tie-split: nothing sent twice", len(sa + sb) == len(set(sa + sb)), str(sa + sb))

# a tie group larger than the limit must not stall forward progress across many polls
reset([row(f"x{i:02d}", 0) for i in range(10)] + [row("later", 4)], max_rows=3)
seen = []
for m in range(5, 11):
    _, _, s = poll(ts(minutes=m))
    seen += s
check("tie-split: large tie group drains completely",
      sorted(seen) == sorted([f"x{i:02d}" for i in range(10)] + ["later"]), str(sorted(seen)))

# ---------------------------------------------------------------- 3. partial failure

reset([row("A", 0), row("B", 1), row("C", 2)])
FakeSession.fail_keys = {"B"}
b, c, s = poll(ts(minutes=5))
check("partial: watermark stops before the failure",
      b["new_watermark"] == main.to_iso_timestamp(ts(minutes=0)), b["new_watermark"])
check("partial: reports failure count", b["rows_failed"] == 1 and b["status"] == "partial", str(b))
FakeSession.fail_keys = set()
b2, _, s2 = poll(ts(minutes=6))
check("partial: failed row retried", "B" in s2, str(s2))
# C succeeded on the first poll even though it sat past the failure, so the cache suppresses it.
# Before the dedup cache this row was necessarily re-sent as a duplicate.
check("partial: already-delivered row past the gap is NOT re-sent", "C" not in s2, str(s2))
check("partial: cursor catches up once the gap closes",
      b2["new_watermark"] == main.to_iso_timestamp(ts(minutes=1)), b2["new_watermark"])

# ---------------------------------------------------------------- 4. total failure -> 500

reset([row("A", 0)])
FakeSession.fail_keys = {"A"}
b, c, _ = poll(ts(minutes=5))
check("total failure returns 500", c == 500, str(c))

# ---------------------------------------------------------------- 5. legacy migration

FakeStorageClient.store.clear()
FakeBigQueryClient.table = [row("A", 0), row("B", 10)]
main.LOOKBACK_MINUTES, main.MAX_ROWS_PER_POLL = 15, 10000
FakeSession.sent, FakeSession.fail_keys = [], set()
FakeStorageClient.store[main.LEGACY_WATERMARK_BLOB] = (main.to_iso_timestamp(ts(minutes=5)), 1)
b, c, s = poll(ts(minutes=20))
# The legacy blob carries no request-id cache, so the first post-upgrade poll re-reads one
# lookback window and re-sends it. Documented, and deduped downstream on request_id.
check("migration: rows past the legacy watermark are sent", "B" in s, str(s))
check("migration: one lookback window is replayed", "A" in s, str(s))
check("migration: new state blob written", main.STATE_BLOB in FakeStorageClient.store)
check("migration: legacy blob left untouched", main.LEGACY_WATERMARK_BLOB in FakeStorageClient.store)
_, _, s_again = poll(ts(minutes=21))
check("migration: replay happens once, not every poll", s_again == [], str(s_again))

# ---------------------------------------------------------------- 6. concurrent write guard

reset([row("A", 0)])
poll(ts(minutes=5))
state, gen = main.read_state(FakeStorageClient())
try:
    main.write_state(FakeStorageClient(), state, gen - 1)
    check("stale generation rejected", False, "no error raised")
except RuntimeError:
    check("stale generation rejected", True)

# ---------------------------------------------------------------- 7. cache pruning + no-id rows

reset([row("A", 0), row("B", 1)])
poll(ts(minutes=5))
st = json.loads(FakeStorageClient.store[main.STATE_BLOB][0])
check("cache remembers delivered ids", set(st["recent"]) == {"A", "B"}, str(st["recent"]))
cutoff = main.parse_iso_timestamp(st["watermark"]) + timedelta(days=1)
check("prune drops entries below the floor", main.prune_recent(st["recent"], cutoff) == {})

reset([{**row("", 0), "request_id": None}])
_, _, s1 = poll(ts(minutes=5))
_, _, s2 = poll(ts(minutes=6))
check("rows without request_id are sent, not suppressed", len(s1) == 1, str(s1))
check("rows without request_id re-send rather than vanish", len(s2) == 1, str(s2))

# ---------------------------------------------------------------- summary

failed = [n for n, ok, _ in results if not ok]
print(f"\n{len(results) - len(failed)}/{len(results)} passed")
if failed:
    print("FAILED: " + ", ".join(failed))
    sys.exit(1)
