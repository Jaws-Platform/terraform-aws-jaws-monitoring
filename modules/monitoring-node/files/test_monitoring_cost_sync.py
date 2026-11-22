"""monitoring-cost-sync when things go wrong, against a fake aws (a local
directory as S3) and a fake psql that records every stream it is sent.

Python 3.9 compatible, like the script (AL2023's python3)."""

import fcntl
import gzip
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "monitoring-cost-sync.py"
FAKE_AWS = HERE.parent / "tests" / "fake_aws_s3.py"
TWINS = HERE.parent.parent / "billing-normalizer" / "files" / "fixtures" / "twin"
PREFIX = "normalized"
AWS_KEY = f"{PREFIX}/schema=focus-1.2/provider=aws/billing_period=2026-11/data.csv.gz"
DATABRICKS_KEY = f"{PREFIX}/schema=focus-1.2/provider=databricks/billing_period=2026-11/data.csv.gz"
RUNS_KEY = f"{PREFIX}/schema=runs-1/event_month=2026-11/data.csv.gz"
PASSWORD = "reader-Secret-123"

# A psql that logs each call (argv and stream) and answers the script's three
# queries. It remembers what was loaded, from the streams' cost.loads upserts.
FAKE_PSQL = textwrap.dedent(r'''
    #!/usr/bin/env python3
    import json, os, re, sys
    log, state = os.environ["FAKE_PSQL_LOG"], os.environ["FAKE_PSQL_STATE"]
    stream = sys.stdin.read()
    with open(log, "a") as f:
        f.write(json.dumps({"argv": sys.argv[1:], "stream": stream}) + "\n")
    if os.environ.get("FAKE_PSQL_DOWN") == "1":
        print("psql: error: connection to server failed", file=sys.stderr); sys.exit(2)
    marker = os.environ.get("FAKE_PSQL_FAIL_ON")
    if marker and marker in stream:
        print("ERROR:  simulated failure", file=sys.stderr); sys.exit(3)
    loaded = json.load(open(state)) if os.path.exists(state) else {}
    for key, etag in re.findall(r"\nSELECT '([^']+)', '(?:focus|runs)', (?:NULL|'[^']*'), '[^']+', '([^']+)'", stream):
        loaded[key] = etag
    for listed in re.findall(r"DELETE FROM cost\.loads WHERE key IN \(([^)]*)\)", stream):
        for key in re.findall(r"'([^']+)'", listed):
            loaded.pop(key, None)
    json.dump(loaded, open(state, "w"))
    if "SELECT value FROM cost.meta" in stream:
        print("3")
    elif "SELECT key || ' ' || etag" in stream:
        print("\n".join(f"{k} {v}" for k, v in loaded.items()))
    elif "SELECT json_build_object" in stream:
        print(json.dumps({"outputs": len(loaded), "newest_charge": {}, "newest_output": {}, "normalizer_last_success": None,
                          "normalizer_latest": None, "overdue": [], "over_ceiling": []}))
''').lstrip()


class Node:
    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.root, self.bucket, self.textfile, self.bin = base / "root", base / "s3/acme-billing", base / "textfile", base / "bin"
        for path in (self.root / "etc/monitoring", self.root / "data/config/current/cost-sync", self.root / "data/secrets",
                     self.bucket, self.textfile, self.bin):
            path.mkdir(parents=True)
        (self.root / "etc/monitoring/node.env").write_text("REGION=us-east-1\n")
        self.config = self.root / "data/config/current/cost-sync/config.json"
        self.config.write_text(json.dumps({"bucket": "acme-billing", "prefix": PREFIX, "providers": ["aws", "databricks"],
                                           "run_join_tags": ["RunId", "TaskId"]}))
        (self.root / "data/secrets/COST_READER_PASSWORD").write_text(PASSWORD)
        (self.bin / "aws").write_text(f'#!/bin/sh\nexec "{sys.executable}" "{FAKE_AWS}" "$@"\n')
        (self.bin / "psql").write_text(FAKE_PSQL.replace("#!/usr/bin/env python3", f"#!{sys.executable}", 1))
        for tool in ("aws", "psql"):
            (self.bin / tool).chmod(0o755)
        self.log, self.state = base / "psql.log", base / "psql-state.json"
        self.env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}", "MONITORING_ROOT": str(self.root),
                    "MONITORING_TEXTFILE_DIR": str(self.textfile), "FAKE_S3_ROOT": str(base / "s3"),
                    "MONITORING_PSQL": f"{self.bin / 'psql'} -U monitoring -v ON_ERROR_STOP=1",
                    "FAKE_PSQL_LOG": str(self.log), "FAKE_PSQL_STATE": str(self.state)}

    def put(self, key, body: bytes):
        path = self.bucket / key
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(body)

    def put_twin(self, key, fixture):
        self.put(key, gzip.compress((TWINS / fixture).read_bytes(), mtime=0))

    def run(self, **env):
        return subprocess.run([sys.executable, str(SCRIPT)], env={**self.env, **env}, capture_output=True, text=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def streams(self):
        return [call["stream"] for call in self.calls()]

    def metrics(self):
        values = {}
        for line in (self.textfile / "cost_sync.prom").read_text().splitlines():
            if line and not line.startswith("#"):
                name, _, value = line.rpartition(" ")
                values[name] = value
        return values

    def last_success(self):
        return json.loads((self.root / "data/cost-sync/state.json").read_text()).get("last_success")


class CostSyncFailureTest(unittest.TestCase):
    def setUp(self):
        self.node = Node()
        self.addCleanup(self.node.tmp.cleanup)

    def good_run(self):
        self.node.put_twin(AWS_KEY, "focus-aws.csv")
        self.node.put_twin(RUNS_KEY, "runs.csv")
        result = self.node.run()
        self.assertEqual(result.returncode, 0, result.stderr)
        return self.node.last_success()

    def test_without_cost_config_it_removes_its_metrics_and_exits_0(self):
        (self.node.textfile / "cost_sync.prom").write_text("monitoring_cost_sync_success 1\n")
        self.node.config.unlink()

        result = self.node.run()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.node.textfile / "cost_sync.prom").exists())
        self.assertEqual(self.node.calls(), [])

    def test_a_bad_output_keeps_its_rows_and_the_rest_load(self):
        self.node.put(AWS_KEY, b"this is not gzip")
        self.node.put(DATABRICKS_KEY, gzip.compress(b'"bad-name","x"\n"1","2"\n'))
        self.node.put_twin(RUNS_KEY, "runs.csv")

        result = self.node.run()

        self.assertEqual(result.returncode, 1)
        self.assertIn(AWS_KEY, result.stderr)
        self.assertIn(DATABRICKS_KEY, result.stderr)
        self.assertEqual(self.node.metrics()["monitoring_cost_sync_success"], "0")
        loads = [s for s in self.node.streams() if "INSERT INTO cost.loads" in s]
        self.assertEqual(len(loads), 1)
        self.assertIn(RUNS_KEY, loads[0])
        # Neither bad output sent anything that would touch its rows.
        self.assertFalse(any(f"WHERE key = '{key}'" in s for s in self.node.streams() for key in (AWS_KEY, DATABRICKS_KEY)))

    def test_with_s3_unreachable_nothing_changes_and_it_says_so(self):
        before = self.good_run()
        streams = len(self.node.streams())
        time.sleep(1)

        result = self.node.run(FAKE_AWS_FAIL="1")

        self.assertEqual(result.returncode, 1)
        self.assertFalse(any("COPY stage" in s or "DELETE FROM" in s for s in self.node.streams()[streams:]))
        self.assertEqual(self.node.metrics(), {"monitoring_cost_sync_success": "0", "monitoring_cost_sync_last_success_seconds": str(before)})

    def test_with_postgres_down_it_says_so(self):
        before = self.good_run()
        time.sleep(1)

        result = self.node.run(FAKE_PSQL_DOWN="1")

        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.node.metrics(), {"monitoring_cost_sync_success": "0", "monitoring_cost_sync_last_success_seconds": str(before)})

    def test_a_failed_load_leaves_the_last_success_alone(self):
        before = self.good_run()
        time.sleep(1)
        rows = (TWINS / "focus-aws.csv").read_bytes().splitlines(keepends=True)
        self.node.put(AWS_KEY, gzip.compress(b"".join(rows[:-1]), mtime=0))  # one row fewer: a new ETag

        result = self.node.run(FAKE_PSQL_FAIL_ON=f"DELETE FROM cost.lines WHERE key = '{AWS_KEY}'")

        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.node.last_success(), before)
        self.assertEqual(self.node.metrics()["monitoring_cost_sync_success"], "0")
        self.assertEqual(self.node.metrics()["monitoring_cost_sync_last_success_seconds"], str(before))

    def test_before_the_normalizers_first_run_it_still_succeeds(self):
        # The role may list only under the prefix, so S3 hides a missing key behind 403.
        self.node.put_twin(RUNS_KEY, "runs.csv")

        result = self.node.run(FAKE_S3_MISSING="403")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.node.metrics()["monitoring_cost_sync_success"], "1")

    def test_the_reader_password_never_reaches_argv(self):
        self.good_run()

        calls = self.node.calls()

        self.assertFalse(any(PASSWORD in " ".join(call["argv"]) for call in calls))
        self.assertTrue(any(PASSWORD in call["stream"] for call in calls))

    def test_runs_one_at_a_time(self):
        lock_path = self.node.root / "run/monitoring-cost-sync.lock"
        lock_path.parent.mkdir(parents=True)
        with open(lock_path, "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            waiting = subprocess.Popen([sys.executable, str(SCRIPT)], env=self.node.env,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            time.sleep(1.5)
            self.assertIsNone(waiting.poll(), "a second run must wait for the first")
            self.assertEqual(self.node.calls(), [])
        waiting.communicate(timeout=60)
        self.assertEqual(waiting.returncode, 0)


if __name__ == "__main__":
    unittest.main()
