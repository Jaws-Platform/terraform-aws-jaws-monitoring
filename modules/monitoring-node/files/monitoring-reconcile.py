#!/usr/bin/env python3
"""monitoring-reconcile: converge the monitoring stack to its config bundle.

Installed by the monitoring-node module. Runs at boot and every 5 minutes
(monitoring-reconcile.timer), one run at a time:

  1. start the current release, with the values it last ran with, before any
     network call: the stack comes up even when S3 or SSM cannot be reached;
  2. read the bundle the node should run (the <prefix>/config-bundle parameter);
     nothing more to do if it is the one running;
  3. download and check it, read every secret it names, make the secrets it
     generates (once, kept on the data volume);
  4. write it as a new release and pull its images (retried) - the running
     stack is untouched until all of that worked;
  5. swap the release and its values in, `docker compose up -d`, and report.

Every run ends with <prefix>/status set to `ok` or `failed:<reason>`:
`missing secret <parameter>`, `bundle <problem>`, `pull`, `up`. Secrets reach
docker compose through its environment, never through a file it parses, so a
value may hold any character.

Python 3.9 (Amazon Linux 2023's python3), stdlib only; `aws` and `docker` are
called as commands.
"""

from __future__ import annotations

import fcntl
import json
import os
import secrets
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Optional

SCHEMA = "monitoring-bundle-1"
PULL_ATTEMPTS = 5


class Failed(Exception):
    """The run failed; the message is the status reason."""


def read_env(path: Path) -> Dict[str, str]:
    values = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, raw = line.partition("=")
            parts = shlex.split(raw)
            values[key] = parts[0] if parts else ""
    return values


class Reconciler:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.node = read_env(root / "etc/monitoring/node.env")
        self.prefix = self.node["PARAMETER_PREFIX"]
        self.config = root / "data/config"
        self.releases = self.config / "releases"
        self.current = self.config / "current"
        self.running_key = self.config / "running-key"
        self.secrets_dir = root / "data/secrets"
        self.stack_file = root / "etc/monitoring/stack.json"
        self.retry_seconds = float(os.environ.get("MONITORING_RETRY_SECONDS", "30"))

    # ------------------------------------------------------------ commands
    def aws(self, *args: str) -> str:
        result = subprocess.run(["aws", "--region", self.node["REGION"], *args], capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or f"aws {' '.join(args[:2])} failed")
        return result.stdout.strip()

    def parameter(self, name: str, decrypt: bool = False) -> str:
        args = ["ssm", "get-parameter", "--name", name, "--query", "Parameter.Value", "--output", "text"]
        if decrypt:
            args.insert(4, "--with-decryption")
        return self.aws(*args)

    def report(self, status: str, running: Optional[str] = None) -> None:
        try:
            self.aws("ssm", "put-parameter", "--name", f"{self.prefix}/status", "--value", status,
                     "--type", "String", "--overwrite")
            if running is not None:
                self.aws("ssm", "put-parameter", "--name", f"{self.prefix}/running-config", "--value", running,
                         "--type", "String", "--overwrite")
        except RuntimeError as error:
            print(f"monitoring-reconcile: could not report {status}: {error}", file=sys.stderr)

    def compose(self, release: Path, values: Dict[str, str], *args: str) -> bool:
        command = ["docker", "compose", "--project-name", "monitoring", "--project-directory", str(release),
                   "-f", str(release / "compose.yaml"), *args]
        return subprocess.run(command, env={**os.environ, **values}).returncode == 0

    # --------------------------------------------------------------- steps
    def stack_values(self) -> Optional[Dict[str, str]]:
        return json.loads(self.stack_file.read_text()) if self.stack_file.exists() else None

    def start_current(self) -> None:
        values = self.stack_values()
        if self.current.is_symlink() and values is not None:
            if not self.compose(self.current.resolve(), values, "up", "-d", "--remove-orphans"):
                print("monitoring-reconcile: could not start the current release", file=sys.stderr)

    def download(self, key: str) -> dict:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "bundle.json"
            try:
                self.aws("s3", "cp", f"s3://{self.node['CONFIG_BUCKET']}/{key}", str(path), "--only-show-errors")
            except RuntimeError:
                raise Failed("bundle download") from None
            try:
                bundle = json.loads(path.read_text())
            except ValueError:
                raise Failed("bundle json") from None
        if not isinstance(bundle, dict) or bundle.get("schema") != SCHEMA:
            raise Failed("bundle schema")
        for field, kind in (("files", dict), ("secrets", dict), ("generated", list)):
            if not isinstance(bundle.get(field), kind):
                raise Failed(f"bundle {field}")
        return bundle

    def values(self, bundle: dict) -> Dict[str, str]:
        values = {}
        for env, name in sorted(bundle["secrets"].items()):
            try:
                values[env] = self.parameter(name, decrypt=True)
            except RuntimeError as error:
                if "ParameterNotFound" in str(error):
                    raise Failed(f"missing secret {name}") from None
                raise Failed(f"secret {name}") from None
        for env in bundle["generated"]:
            path = self.secrets_dir / env
            if not path.exists():
                path.write_text(secrets.token_urlsafe(32))
                path.chmod(0o600)
            values[env] = path.read_text().strip()
        return values

    def write_release(self, key: str, bundle: dict) -> Path:
        release = self.releases / Path(key).stem
        for relative, content in bundle["files"].items():
            target = (release / relative).resolve()
            if Path(relative).is_absolute() or release.resolve() not in target.parents:
                raise Failed(f"bundle path {relative}")
        for relative, content in bundle["files"].items():
            target = release / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)
        return release

    def pull(self, release: Path, values: Dict[str, str]) -> None:
        for attempt in range(1, PULL_ATTEMPTS + 1):
            if self.compose(release, values, "pull"):
                return
            if attempt < PULL_ATTEMPTS:
                time.sleep(self.retry_seconds * attempt)
        raise Failed("pull")

    def swap(self, key: str, release: Path, values: Dict[str, str]) -> None:
        link = self.config / "current.next"
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(release)
        stack_next = self.stack_file.with_suffix(".json.next")
        stack_next.write_text(json.dumps(values))
        stack_next.chmod(0o600)
        os.replace(link, self.current)
        os.replace(stack_next, self.stack_file)
        self.running_key.write_text(key)

    # ----------------------------------------------------------------- run
    def run(self, force: bool) -> int:
        self.start_current()
        try:
            key = self.parameter(f"{self.prefix}/config-bundle")
        except RuntimeError as error:
            print(f"monitoring-reconcile: cannot read the bundle name: {error}", file=sys.stderr)
            self.report("failed:config-bundle")
            return 1
        running = self.running_key.read_text().strip() if self.running_key.exists() else None
        if key == running and not force:
            return 0
        try:
            bundle = self.download(key)
            values = self.values(bundle)
            release = self.write_release(key, bundle)
            self.pull(release, values)
            self.swap(key, release, values)
            if not self.compose(release, values, "up", "-d", "--remove-orphans"):
                raise Failed("up")
        except Failed as failure:
            self.report(f"failed:{failure}")
            print(f"monitoring-reconcile: failed: {failure}", file=sys.stderr)
            return 1
        self.report("ok", running=key)
        print(f"monitoring-reconcile: running {key}")
        return 0


def main(argv: List[str]) -> int:
    root = Path(os.environ.get("MONITORING_ROOT", "/"))
    (root / "run").mkdir(parents=True, exist_ok=True)
    with open(root / "run/monitoring-reconcile.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return Reconciler(root).run(force="--force" in argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
