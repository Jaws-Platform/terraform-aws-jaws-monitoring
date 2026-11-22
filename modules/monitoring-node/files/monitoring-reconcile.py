#!/usr/bin/env python3
"""monitoring-reconcile: converge the monitoring stack to its config bundle.

Installed by the monitoring-node module. Runs at boot and every 5 minutes
(monitoring-reconcile.timer), one run at a time:

  1. start the current release, with the values it last ran with, before any
     network call: the stack comes up even when S3 or SSM cannot be reached;
  2. read the bundle the node should run (the <prefix>/config-bundle parameter)
     and the secrets it names; if neither changed, that is all;
  3. otherwise download and check the bundle, make the secrets it generates
     (once, kept on the data volume), write it as a new release and pull its
     images (retried) - the running stack is untouched until all of that worked;
  4. save the values, swap the release in, `docker compose up -d`; a rotated
     Grafana admin password is then applied with Grafana's own reset.

What this node runs is recorded on the root volume, next to the values it runs
with, so a replaced instance (a new root volume, the same data volume) always
reconciles in full. <prefix>/status says how the last run went: `ok` or
`failed:<reason>` - `missing secret <parameter>`, `bundle <problem>`, `pull`,
`up`, `password-reset`, `internal <error>` - and is written only when it
changes. Secrets reach docker compose through its environment, never through a
file it parses, so a value may hold any character.

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
ADMIN_PASSWORD = "GF_SECURITY_ADMIN_PASSWORD"


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


def write_private(path: Path, text: str) -> None:
    """Write a 0600 file atomically: a crash never leaves it half written."""
    tmp = path.with_name(f".{path.name}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        handle.write(text)
    os.replace(tmp, path)


class Reconciler:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.etc = root / "etc/monitoring"
        self.node = read_env(self.etc / "node.env")
        self.prefix = self.node["PARAMETER_PREFIX"]
        self.config = root / "data/config"
        self.releases = self.config / "releases"
        self.current = self.config / "current"
        self.secrets_dir = root / "data/secrets"
        # On the root volume, together: a new instance has neither.
        self.stack_file = self.etc / "stack.json"
        self.running_key = self.etc / "running-key"
        self.last_status = self.etc / "last-status"
        self.retry_seconds = float(os.environ.get("MONITORING_RETRY_SECONDS", "30"))

    # ------------------------------------------------------------ commands
    def aws(self, *args: str) -> str:
        result = subprocess.run(["aws", "--region", self.node["REGION"], *args], capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or f"aws {' '.join(args[:2])} failed")
        return result.stdout.rstrip("\n")

    def parameter(self, name: str, decrypt: bool = False) -> str:
        args = ["ssm", "get-parameter", "--name", name, "--query", "Parameter.Value", "--output", "text"]
        if decrypt:
            args.insert(4, "--with-decryption")
        return self.aws(*args)

    def report(self, status: str, running: Optional[str] = None) -> None:
        """Write the status (and what runs) to SSM, but only when it changed."""
        previous = self.last_status.read_text() if self.last_status.exists() else None
        if status == previous and running is None:
            return
        try:
            self.aws("ssm", "put-parameter", "--name", f"{self.prefix}/status", "--value", status,
                     "--type", "String", "--overwrite")
            if running is not None:
                self.aws("ssm", "put-parameter", "--name", f"{self.prefix}/running-config", "--value", running,
                         "--type", "String", "--overwrite")
            self.last_status.write_text(status)
        except RuntimeError as error:
            print(f"monitoring-reconcile: could not report {status}: {error}", file=sys.stderr)

    def compose(self, release: Path, values: Dict[str, str], *args: str, stdin: Optional[str] = None) -> bool:
        command = ["docker", "compose", "--project-name", "monitoring", "--project-directory", str(release),
                   "-f", str(release / "compose.yaml"), *args]
        return subprocess.run(command, env={**os.environ, **values}, input=stdin, text=True).returncode == 0

    # --------------------------------------------------------------- steps
    def stack_values(self) -> Optional[Dict[str, str]]:
        return json.loads(self.stack_file.read_text()) if self.stack_file.exists() else None

    def start_current(self) -> bool:
        """Start what ran last; False only if it exists and would not start."""
        values = self.stack_values()
        if not (self.current.is_symlink() and values is not None):
            return True
        if self.compose(self.current.resolve(), values, "up", "-d", "--remove-orphans"):
            return True
        print("monitoring-reconcile: the current release would not start", file=sys.stderr)
        return False

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

    def read_secrets(self, names: Dict[str, str]) -> Dict[str, str]:
        values = {}
        for env, name in sorted(names.items()):
            try:
                values[env] = self.parameter(name, decrypt=True)
            except RuntimeError as error:
                if "ParameterNotFound" in str(error):
                    raise Failed(f"missing secret {name}") from None
                raise Failed(f"secret {name}") from None
        return values

    def generated(self, names: List[str]) -> Dict[str, str]:
        values = {}
        for env in names:
            path = self.secrets_dir / env
            value = path.read_text().strip() if path.exists() else ""
            if not value:
                value = secrets.token_urlsafe(32)
                write_private(path, value)
            values[env] = value
        return values

    def write_release(self, key: str, bundle: dict) -> Path:
        release = self.releases / Path(key).stem
        for relative in bundle["files"]:
            target = (release / relative).resolve()
            if Path(relative).is_absolute() or release.resolve() not in target.parents:
                raise Failed(f"bundle path {relative}")
        for relative, content in bundle["files"].items():
            target = release / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)
        (release / ".bundle-secrets.json").write_text(json.dumps(bundle["secrets"]))
        return release

    def pull(self, release: Path, values: Dict[str, str]) -> None:
        for attempt in range(1, PULL_ATTEMPTS + 1):
            if self.compose(release, values, "pull"):
                return
            if attempt < PULL_ATTEMPTS:
                time.sleep(self.retry_seconds * attempt)
        raise Failed("pull")

    def swap(self, release: Path, values: Dict[str, str]) -> None:
        write_private(self.stack_file, json.dumps(values))
        link = self.config / "current.next"
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(release)
        os.replace(link, self.current)

    def start_cost_sync(self, release: Path) -> None:
        """A release can add views the cost rules read: cost-sync builds them now,
        not at its next tick, up to 30 minutes on with every cost rule failing.
        Best effort: the timer still runs it."""
        if not (release / "cost-sync/monitoring-cost-sync.py").exists():
            return
        result = subprocess.run(["systemctl", "start", "--no-block", "monitoring-cost-sync.service"],
                                capture_output=True, text=True)
        if result.returncode != 0:
            print(f"monitoring-reconcile: couldn't start cost-sync: {result.stderr.strip() or result.returncode}",
                  file=sys.stderr)

    def reset_admin_password(self, release: Path, values: Dict[str, str]) -> None:
        if not self.compose(release, values, "exec", "-T", "grafana", "grafana", "cli", "admin",
                            "reset-admin-password", "--password-from-stdin", stdin=values[ADMIN_PASSWORD]):
            raise Failed("password-reset")

    # ----------------------------------------------------------------- run
    def unchanged(self, key: str) -> Optional[bool]:
        """None if the bundle changed; else whether its secrets are also unchanged."""
        running = self.running_key.read_text().strip() if self.running_key.exists() else None
        values = self.stack_values()
        if key != running or values is None or not self.current.is_symlink():
            return None
        names_file = self.current.resolve() / ".bundle-secrets.json"
        names = json.loads(names_file.read_text()) if names_file.exists() else {}
        fresh = self.read_secrets(names)
        return all(values.get(env) == value for env, value in fresh.items())

    def converge(self, key: str, previous: Optional[Dict[str, str]]) -> None:
        bundle = self.download(key)
        values = {**self.read_secrets(bundle["secrets"]), **self.generated(bundle["generated"])}
        release = self.write_release(key, bundle)
        self.pull(release, values)
        self.swap(release, values)
        if not self.compose(release, values, "up", "-d", "--remove-orphans"):
            raise Failed("up")
        self.start_cost_sync(release)
        rotated = previous is not None and ADMIN_PASSWORD in values and previous.get(ADMIN_PASSWORD) != values[ADMIN_PASSWORD]
        if rotated:
            self.reset_admin_password(release, values)
        self.running_key.write_text(key)

    def run(self, force: bool) -> int:
        started = self.start_current()
        try:
            key = self.parameter(f"{self.prefix}/config-bundle")
        except RuntimeError as error:
            print(f"monitoring-reconcile: cannot read the bundle name: {error}", file=sys.stderr)
            self.report("failed:config-bundle")
            return 1
        try:
            same = None if force else self.unchanged(key)
            if same:
                if not started:
                    raise Failed("up")
                self.report("ok")
                return 0
            self.converge(key, self.stack_values())
        except Failed as failure:
            self.report(f"failed:{failure}")
            print(f"monitoring-reconcile: failed: {failure}", file=sys.stderr)
            return 1
        except Exception as error:  # report anything unforeseen, never die silently
            self.report(f"failed:internal {type(error).__name__}")
            print(f"monitoring-reconcile: failed: {error!r}", file=sys.stderr)
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
