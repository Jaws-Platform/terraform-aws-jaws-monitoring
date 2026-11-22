"""Behavioural tests for monitoring-reconcile.py.

The real script runs against fake `aws` and `docker` executables that keep the
SSM parameters, the S3 objects and every call in a JSON state file, in a
temporary root (MONITORING_ROOT). Stdlib only.

Run: python3 -m unittest discover -s modules/monitoring-node/files -p 'test_*.py'
"""

import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "monitoring-reconcile.py"
BUCKET = "acme-monitoring-config-123456789012"
PREFIX = "/acme-monitoring/node"
USER = "/acme/monitoring/grafana-admin-user"
PASSWORD = "/acme/monitoring/grafana-admin-password"

FAKE_AWS = r'''#!/usr/bin/env python3
import json, os, sys
path = os.environ["FAKE_STATE"]
s = json.load(open(path))
args = sys.argv[1:]
s["calls"].append(["aws"] + args)
while args and args[0] in ("--region", "--profile"):
    args = args[2:]  # global options come before the command
def save():
    json.dump(s, open(path, "w"))
def opt(name):
    return args[args.index(name) + 1]
if s["fail"].get("aws"):
    save(); sys.stderr.write("Could not connect to the endpoint URL\n"); sys.exit(255)
if args[:2] == ["ssm", "get-parameter"]:
    name = opt("--name")
    if name not in s["params"]:
        save(); sys.stderr.write("An error occurred (ParameterNotFound) when calling the GetParameter operation\n"); sys.exit(254)
    save(); print(s["params"][name]); sys.exit(0)
if args[:2] == ["ssm", "put-parameter"]:
    s["params"][opt("--name")] = opt("--value"); save(); sys.exit(0)
if args[:2] == ["s3", "cp"]:
    source, dest = args[2], args[3]
    if source not in s["objects"]:
        save(); sys.stderr.write("fatal error: NoSuchKey\n"); sys.exit(1)
    open(dest, "w").write(s["objects"][source]); save(); sys.exit(0)
save(); sys.stderr.write("unexpected aws call\n"); sys.exit(2)
'''

FAKE_DOCKER = r'''#!/usr/bin/env python3
import json, os, sys
path = os.environ["FAKE_STATE"]
s = json.load(open(path))
args = sys.argv[1:]
s["calls"].append(["docker"] + args)
s.setdefault("env_seen", []).append(os.environ.get("GF_SECURITY_ADMIN_PASSWORD"))
code = 0
if "pull" in args and s["fail"].get("pull", 0) > 0:
    s["fail"]["pull"] -= 1; code = 1
if "up" in args and s["fail"].get("up"):
    code = 1
json.dump(s, open(path, "w")); sys.exit(code)
'''


def bundle(text="v1"):
    return json.dumps({
        "schema": "monitoring-bundle-1",
        "files": {"compose.yaml": f"services: {{}}  # {text}\n", "prometheus/prometheus.yml": f"# {text}\n"},
        "secrets": {"GF_SECURITY_ADMIN_USER": USER, "GF_SECURITY_ADMIN_PASSWORD": PASSWORD},
        "generated": ["POSTGRES_PASSWORD"],
    })


class Node:
    """A temporary node root with fake aws and docker, and the reconciler to run in it."""

    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "etc/monitoring").mkdir(parents=True)
        (self.root / "data/config/releases").mkdir(parents=True)
        (self.root / "data/secrets").mkdir(parents=True)
        (self.root / "run").mkdir()
        (self.root / "etc/monitoring/node.env").write_text(
            f"NAME='acme-monitoring'\nREGION='us-east-1'\nPARAMETER_PREFIX='{PREFIX}'\nCONFIG_BUCKET='{BUCKET}'\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, body in (("aws", FAKE_AWS), ("docker", FAKE_DOCKER)):
            path = self.bin / name
            path.write_text(body.replace("#!/usr/bin/env python3", f"#!{sys.executable}", 1))
            path.chmod(path.stat().st_mode | stat.S_IEXEC)
        self.state_path = self.root / "state.json"
        self.state = {"params": {f"{PREFIX}/config-bundle": "bundles/aaa.json", USER: "admin", PASSWORD: "s3cret 'x' $y"},
                      "objects": {f"s3://{BUCKET}/bundles/aaa.json": bundle("v1")}, "fail": {}, "calls": []}
        self.save()

    def save(self):
        self.state_path.write_text(json.dumps(self.state))

    def load(self):
        self.state = json.loads(self.state_path.read_text())
        return self.state

    def publish(self, key, body):
        self.load()
        self.state["params"][f"{PREFIX}/config-bundle"] = key
        self.state["objects"][f"s3://{BUCKET}/{key}"] = body
        self.save()

    def run(self):
        self.load()
        self.state["calls"] = []
        self.save()
        env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", MONITORING_ROOT=str(self.root),
                   FAKE_STATE=str(self.state_path), MONITORING_RETRY_SECONDS="0")
        result = subprocess.run([sys.executable, str(SCRIPT)], env=env, capture_output=True, text=True)
        self.load()
        return result

    def calls(self, tool, *words):
        return [c for c in self.state["calls"] if c[0] == tool and all(w in c for w in words)]

    def current(self):
        link = self.root / "data/config/current"
        return os.readlink(link) if link.is_symlink() else None

    def stack(self):
        return json.loads((self.root / "etc/monitoring/stack.json").read_text())


class ReconcileTest(unittest.TestCase):
    def setUp(self):
        self.node = Node()
        self.addCleanup(self.node.tmp.cleanup)

    def test_a_first_run_installs_the_bundle_and_starts_the_stack(self):
        result = self.node.run()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.node.current(), str(self.node.root / "data/config/releases/aaa"))
        release = self.node.root / "data/config/releases/aaa"
        self.assertEqual((release / "prometheus/prometheus.yml").read_text(), "# v1\n")
        stack_file = self.node.root / "etc/monitoring/stack.json"
        self.assertEqual(stat.S_IMODE(stack_file.stat().st_mode), 0o600)
        stack = self.node.stack()
        self.assertEqual((stack["GF_SECURITY_ADMIN_USER"], stack["GF_SECURITY_ADMIN_PASSWORD"]), ("admin", "s3cret 'x' $y"))
        self.assertGreaterEqual(len(stack["POSTGRES_PASSWORD"]), 32)
        compose = [c for c in self.node.calls("docker", "compose")]
        self.assertEqual([("pull" in c, "up" in c) for c in compose], [(True, False), (False, True)])
        self.assertIn("--remove-orphans", compose[-1])
        self.assertIn("s3cret 'x' $y", self.node.state["env_seen"])
        self.assertEqual(self.node.state["params"][f"{PREFIX}/status"], "ok")
        self.assertEqual(self.node.state["params"][f"{PREFIX}/running-config"], "bundles/aaa.json")

    def test_an_unchanged_bundle_only_ensures_the_stack_is_up(self):
        self.node.run()

        result = self.node.run()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.node.calls("aws", "s3"), [])
        self.assertEqual(self.node.calls("docker", "pull"), [])
        self.assertEqual(len(self.node.calls("docker", "up")), 1)

    def test_a_new_bundle_swaps_the_release(self):
        self.node.run()
        self.node.publish("bundles/bbb.json", bundle("v2"))

        result = self.node.run()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.node.current(), str(self.node.root / "data/config/releases/bbb"))
        self.assertEqual((self.node.root / "data/config/current/prometheus/prometheus.yml").read_text(), "# v2\n")
        self.assertEqual(self.node.state["params"][f"{PREFIX}/running-config"], "bundles/bbb.json")

    def test_generated_secrets_are_made_once(self):
        self.node.run()
        first = self.node.stack()["POSTGRES_PASSWORD"]
        self.node.publish("bundles/bbb.json", bundle("v2"))

        self.node.run()

        self.assertEqual(self.node.stack()["POSTGRES_PASSWORD"], first)

    def test_a_missing_secret_changes_nothing_and_says_which(self):
        self.node.run()
        self.node.publish("bundles/bbb.json", bundle("v2"))
        del self.node.state["params"][PASSWORD]
        self.node.save()

        result = self.node.run()

        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.node.state["params"][f"{PREFIX}/status"], f"failed:missing secret {PASSWORD}")
        self.assertEqual(self.node.calls("docker", "pull"), [])
        self.assertEqual(self.node.current(), str(self.node.root / "data/config/releases/aaa"))

    def test_a_failed_pull_keeps_the_running_release(self):
        self.node.run()
        self.node.publish("bundles/bbb.json", bundle("v2"))
        self.node.state["fail"]["pull"] = 5
        self.node.save()

        result = self.node.run()

        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(self.node.calls("docker", "pull")), 5)
        self.assertEqual(self.node.state["params"][f"{PREFIX}/status"], "failed:pull")
        self.assertEqual(self.node.current(), str(self.node.root / "data/config/releases/aaa"))

    def test_a_bad_bundle_is_refused(self):
        self.node.publish("bundles/bad.json", json.dumps({"schema": "monitoring-bundle-0", "files": {}}))

        result = self.node.run()

        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.node.state["params"][f"{PREFIX}/status"], "failed:bundle schema")
        self.assertIsNone(self.node.current())

    def test_a_bundle_cannot_write_outside_its_release(self):
        self.node.publish("bundles/evil.json", json.dumps({"schema": "monitoring-bundle-1", "files": {"../../etc/x": "y"},
                                                           "secrets": {}, "generated": []}))

        result = self.node.run()

        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.node.state["params"][f"{PREFIX}/status"], "failed:bundle path ../../etc/x")
        self.assertFalse((self.node.root / "etc/x").exists())

    def test_with_ssm_unreachable_the_current_release_still_starts(self):
        self.node.run()
        self.node.state["fail"]["aws"] = True
        self.node.save()

        result = self.node.run()

        self.assertEqual(result.returncode, 1)
        ups = self.node.calls("docker", "up")
        self.assertEqual(len(ups), 1)
        self.assertIn(str(self.node.root / "data/config/releases/aaa"), " ".join(ups[0]))
        self.assertIn("s3cret 'x' $y", self.node.state["env_seen"])


if __name__ == "__main__":
    unittest.main()
