#!/usr/bin/env python3
"""Helper for test-grafana-provisioning.sh: write a rendered release, list its
PromQL, and compare what a running Grafana reports with what was rendered.

  grafana_smoke.py write   <files.json> <release dir>
  grafana_smoke.py queries <release dir> <promtool rules file>
  grafana_smoke.py env     <release dir>          webhook variables Grafana expands
  grafana_smoke.py compare <release dir> <url> <user> <password> <phase>

Standard library only: the alerting files are JSON for this reason.
"""

from __future__ import annotations

import base64
import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

WAIT_SECONDS = 90


def write(files_json: str, release: str) -> None:
    files = json.loads(Path(files_json).read_text())
    root = Path(release)
    for rel, content in files.items():
        if not rel.startswith("grafana/"):
            raise SystemExit(f"grafana smoke: unexpected file {rel}")
        target = root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
    # Grafana's mounts must exist even when nothing was rendered into them.
    for sub in ("grafana/dashboards", "grafana/provisioning/alerting"):
        (root / sub).mkdir(parents=True, exist_ok=True)


def alerting_docs(release: Path) -> dict:
    return {p.name: json.loads(p.read_text()) for p in sorted((release / "grafana/provisioning/alerting").glob("*.json"))}


def dashboards(release: Path) -> dict:
    return {str(p.relative_to(release / "grafana/dashboards")): json.loads(p.read_text())
            for p in sorted((release / "grafana/dashboards").rglob("*.json"))}


def rendered(release: Path) -> dict:
    docs = alerting_docs(release)
    groups = [g for d in docs.values() for g in d.get("groups", [])]
    contact_points = [c["name"] for d in docs.values() for c in d.get("contactPoints", [])]
    templates = [t["name"] for d in docs.values() for t in d.get("templates", [])]
    policies = [p for d in docs.values() for p in d.get("policies", [])]
    reset = any(d.get("resetPolicies") for d in docs.values())
    boards = dashboards(release)
    datasources = re.findall(r'"uid": "([^"]+)"', (release / "grafana/provisioning/datasources/datasources.yaml").read_text())
    return {
        "rules": sorted(r["uid"] for g in groups for r in g.get("rules", [])),
        "dashboards": sorted(b["uid"] for b in boards.values()),
        "folders": sorted({g["folder"] for g in groups} | {Path(p).parts[0] for p in boards if len(Path(p).parts) > 1}),
        "datasources": sorted(datasources),
        "contact_points": sorted(contact_points),
        "templates": sorted(templates),
        "root_receiver": policies[0]["receiver"] if policies else None,
        "reset_policies": reset,
    }


def panels(board: dict) -> list:
    out = []
    for p in board.get("panels", []):
        out.append(p)
        out.extend(p.get("panels", []))
    return out


def queries(release: str, out: str) -> None:
    root = Path(release)
    exprs = []
    for doc in alerting_docs(root).values():
        for g in doc.get("groups", []):
            for r in g.get("rules", []):
                for d in r.get("data", []):
                    if d.get("datasourceUid") == "prometheus":
                        exprs.append(d["model"]["expr"])
    for board in dashboards(root).values():
        for p in panels(board):
            for t in p.get("targets", []):
                uid = (t.get("datasource") or p.get("datasource") or {}).get("uid")
                if uid == "prometheus" and t.get("expr"):
                    exprs.append(t["expr"])
    unique = sorted(set(exprs))
    rules =[{"record": f"smoke:q{i}", "expr": e} for i, e in enumerate(unique, 1)]
    Path(out).write_text(json.dumps({"groups": [{"name": "smoke", "rules": rules}]}))
    print(len(unique))


def env(release: str) -> None:
    found = set()
    for p in (Path(release) / "grafana/provisioning/alerting").glob("*.json"):
        found.update(re.findall(r"\$(SLACK_WEBHOOK_[A-Z0-9_]+)", p.read_text()))
    print("\n".join(sorted(found)))


def api(url: str, auth: str, path: str):
    request = urllib.request.Request(url + path, headers={"Authorization": f"Basic {auth}"})
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.loads(response.read())


def observed(url: str, auth: str) -> dict:
    folders = [f["title"] for f in api(url, auth, "/api/folders")]
    policy = api(url, auth, "/api/v1/provisioning/policies")
    return {
        "rules": sorted(r["uid"] for r in api(url, auth, "/api/v1/provisioning/alert-rules")),
        "dashboards": sorted(d["uid"] for d in api(url, auth, "/api/search?type=dash-db")),
        "folders": folders,
        "datasources": sorted(d["uid"] for d in api(url, auth, "/api/datasources")),
        "contact_points": sorted({c["name"] for c in api(url, auth, "/api/v1/provisioning/contact-points")}),
        "templates": sorted(t["name"] for t in api(url, auth, "/api/v1/provisioning/templates")),
        "root_receiver": policy.get("receiver"),
    }


def problems(want: dict, got: dict) -> list:
    found = []
    for key in ("rules", "dashboards", "datasources"):
        if want[key] != got[key]:
            found.append(f"{key}: rendered {want[key]}, Grafana has {got[key]}")
    duplicated = sorted({f for f in got["folders"] if got["folders"].count(f) > 1})
    if duplicated:
        found.append(f"folders: more than one folder titled {duplicated}")
    missing = sorted(set(want["folders"]) - set(got["folders"]))
    if missing:
        found.append(f"folders: rendered {missing}, missing from Grafana")
    for key in ("contact_points", "templates"):
        absent = sorted(set(want[key]) - set(got[key]))
        if absent:
            found.append(f"{key}: rendered {absent}, missing from Grafana")
    if want["root_receiver"] and want["root_receiver"] != got["root_receiver"]:
        found.append(f"policies: root receiver should be {want['root_receiver']}, is {got['root_receiver']}")
    if want["reset_policies"] and str(got["root_receiver"]).startswith("slack-"):
        found.append(f"policies: should be reset, root receiver is still {got['root_receiver']}")
    return found


def compare(release: str, url: str, user: str, password: str, phase: str) -> None:
    want = rendered(Path(release))
    auth = base64.b64encode(f"{user}:{password}".encode()).decode()
    deadline = time.time() + WAIT_SECONDS
    while True:
        # Dashboards are provisioned in the background after startup: retry
        # until Grafana agrees or the wait runs out.
        try:
            found = problems(want, observed(url, auth))
        except (urllib.error.URLError, OSError, ValueError) as error:
            found = [f"api: {error}"]
        if not found:
            break
        if time.time() > deadline:
            for line in found:
                print(f"grafana smoke ({phase}): {line}", file=sys.stderr)
            raise SystemExit(1)
        time.sleep(3)
    print(f"grafana smoke ({phase}): {len(want['rules'])} rules, {len(want['dashboards'])} dashboards, "
          f"{len(want['contact_points'])} contact points, root receiver {want['root_receiver'] or 'default'} - as rendered")


def main(argv: list) -> None:
    commands = {"write": write, "queries": queries, "env": env, "compare": compare}
    if not argv or argv[0] not in commands:
        raise SystemExit(__doc__)
    commands[argv[0]](*argv[1:])


if __name__ == "__main__":
    main(sys.argv[1:])
