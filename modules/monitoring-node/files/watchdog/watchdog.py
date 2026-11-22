"""The monitoring node's watchdog (spec 6.9): a Lambda outside the node, so a
dead node still gets reported. EventBridge Scheduler runs it every 5 minutes,
and the status-check alarms' SNS topic runs it at once; both are judged alike.

It posts to the host channel's Slack webhook when the node:

- isn't running when it should be: critical, on 2 checks in a row, outside the
  15 minutes after a scheduled start;
- is running in its off window: a warning, outside the 15 minutes after a
  scheduled stop (a stop that failed quietly costs money);
- with a domain, doesn't answer https://<domain>/api/health: critical, on 2
  checks in a row, never in the 15 minutes after any start;
- fails an EC2 status check: critical, while its alarm is in ALARM.

A problem posts once, again every 4 hours while it lasts, and once when it
resolves. The state lives in an SSM parameter, saved only after every post went
through, so a failed post is retried on the next run.

Standard library plus boto3 (imported only by default_clients).
"""

from __future__ import annotations

import json
import os
import urllib.request
from datetime import datetime, time, timedelta, timezone
from typing import Callable, Dict, List, Optional, Tuple
from zoneinfo import ZoneInfo

GRACE_MINUTES = 15
REPEAT_HOURS = 4
DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
ALARM_KEYS = ["status-system", "status-instance"]
TITLES = {
    "not-running": "Monitoring node not running",
    "running-off-hours": "Monitoring node running off-hours",
    "health": "Grafana not answering",
    "status-system": "EC2 system status check failed",
    "status-instance": "EC2 instance status check failed",
}


# ------------------------------------------------------------- the window
def _hour(text: str) -> int:
    return int(text[:2])


def should_run(now: datetime, schedule: Optional[dict]) -> bool:
    """Whether the node should be running at now. Always, with no schedule."""
    if not schedule:
        return True
    local = now.astimezone(ZoneInfo(schedule["timezone"]))
    if DAYS[local.weekday()] not in schedule["days"]:
        return False
    return _hour(schedule["on"]) <= local.hour < _hour(schedule["off"])


def _boundaries(now: datetime, schedule: dict) -> List[datetime]:
    """Today's and yesterday's scheduled starts and stops, in local time."""
    zone = ZoneInfo(schedule["timezone"])
    today = now.astimezone(zone).date()
    found = []
    for back in (0, 1):
        day = today - timedelta(days=back)
        if DAYS[day.weekday()] not in schedule["days"]:
            continue
        found.append(datetime.combine(day, time(_hour(schedule["on"])), tzinfo=zone))
        off = _hour(schedule["off"])
        stop_day, stop_hour = (day + timedelta(days=1), 0) if off == 24 else (day, off)
        found.append(datetime.combine(stop_day, time(stop_hour), tzinfo=zone))
    return found


def in_grace(now: datetime, schedule: Optional[dict], minutes: int = GRACE_MINUTES) -> bool:
    """Whether now is within minutes after a scheduled start or stop."""
    if not schedule:
        return False
    return any(timedelta(0) <= now - b < timedelta(minutes=minutes) for b in _boundaries(now, schedule))


# ---------------------------------------------------------------- judging
def _problem(key: str, severity: str, detail: str) -> dict:
    return {"severity": severity, "title": TITLES[key], "detail": detail}


def assess(now: datetime, instance_state: str, schedule: Optional[dict], alarms: Dict[str, str],
           health_ok: Optional[bool], counters: dict) -> Tuple[Dict[str, dict], dict]:
    """The current problems by key, and the new counters. health_ok is None
    when the health check wasn't run."""
    counters = {"not_running": int(counters.get("not_running", 0)), "health": int(counters.get("health", 0))}
    problems: Dict[str, dict] = {}
    run, grace = should_run(now, schedule), in_grace(now, schedule)

    if run and instance_state not in ("pending", "running") and not grace:
        counters["not_running"] += 1
        if counters["not_running"] >= 2:
            when = "on its schedule" if schedule else "all day"
            problems["not-running"] = _problem("not-running", "critical", f"The instance is {instance_state}; it should be running {when}.")
    else:
        counters["not_running"] = 0

    if not run and instance_state == "running" and not grace:
        problems["running-off-hours"] = _problem(
            "running-off-hours", "warning", "The instance is running in its off window: a scheduled stop didn't happen, and it is costing money.")

    if health_ok is None or health_ok:
        counters["health"] = 0
    else:
        counters["health"] += 1
        if counters["health"] >= 2:
            problems["health"] = _problem("health", "critical", "Grafana's /api/health failed twice in a row.")

    for key in ALARM_KEYS:
        if alarms.get(key) == "ALARM":
            action = "EC2 is recovering it" if key == "status-system" else "EC2 is rebooting it"
            problems[key] = _problem(key, "critical", f"Its CloudWatch alarm is in ALARM; {action}.")
    return problems, counters


def _iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).isoformat()


def notify(state: dict, problems: Dict[str, dict], now: datetime, repeat_hours: int = REPEAT_HOURS,
           node: str = "") -> Tuple[List[str], dict]:
    """The messages to post, and the new state."""
    old = state.get("problems") or {}
    messages, new = [], {}
    for key, p in sorted(problems.items()):
        prev = old.get(key)
        due = prev is None or now - datetime.fromisoformat(prev["posted"]) >= timedelta(hours=repeat_hours)
        if due:
            messages.append(f"🚨 [FIRING] {p['title']} — severity: {p['severity']}\n{p['detail']}\nNode: {node}")
        new[key] = {**p, "since": prev["since"] if prev else _iso(now), "posted": _iso(now) if due else prev["posted"]}
    for key, prev in sorted(old.items()):
        if key not in problems:
            messages.append(f"✅ [RESOLVED] {prev['title']}\nNode: {node}")
    return messages, {"problems": new, "counters": state.get("counters") or {}}


# ------------------------------------------------------------------- I/O
def http_ok(url: str) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            return response.status == 200
    except Exception:  # any failure to answer is a failed check
        return False


def post_json(url: str, text: str) -> None:
    body = json.dumps({"text": text}).encode()
    request = urllib.request.Request(url, data=body, method="POST", headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=10) as response:
        if response.status >= 300:
            raise OSError(f"Slack answered {response.status}")


def default_clients() -> Dict[str, object]:
    import boto3  # the Lambda runtime has it; the unit tests never need it

    return {"ec2": boto3.client("ec2"), "cloudwatch": boto3.client("cloudwatch"), "ssm": boto3.client("ssm"),
            "http": http_ok, "post": post_json, "now": lambda: datetime.now(timezone.utc)}


def _load_state(ssm, name: str) -> dict:
    try:
        state = json.loads(ssm.get_parameter(Name=name)["Parameter"]["Value"])
        return state if isinstance(state, dict) else {}
    except Exception:  # missing or unreadable state starts fresh
        return {}


def _instance(ec2, instance_id: str) -> Tuple[str, Optional[datetime]]:
    """The instance's state, and when it last started (LaunchTime is reset by
    every start, not by a reboot)."""
    try:
        reservations = ec2.describe_instances(InstanceIds=[instance_id])["Reservations"]
        if not reservations:
            return "missing", None
        instance = reservations[0]["Instances"][0]
        return instance["State"]["Name"], instance.get("LaunchTime")
    except Exception as error:  # an instance that's gone reads as missing
        if "InvalidInstanceID" in str(error):
            return "missing", None
        raise


def handler(event, context, clients: Optional[Dict[str, object]] = None) -> dict:
    """One check. An SNS event (a status-check alarm) and a scheduled event are
    handled the same way: everything is looked up afresh."""
    clients = clients or default_clients()
    env = os.environ
    schedule = json.loads(env["SCHEDULE"]) if env.get("SCHEDULE") else None
    domain = env.get("DOMAIN") or ""
    instance_id = env["INSTANCE_ID"]
    now: datetime = clients["now"]()  # type: ignore[operator]

    state = _load_state(clients["ssm"], env["STATE_PARAMETER"])
    instance_state, launched = _instance(clients["ec2"], instance_id)
    names = [n for n in env.get("ALARMS", "").split(",") if n]
    found = {a["AlarmName"]: a["StateValue"] for a in clients["cloudwatch"].describe_alarms(AlarmNames=names)["MetricAlarms"]} if names else {}  # type: ignore[attr-defined]
    alarms = {key: found.get(name, "OK") for key, name in zip(ALARM_KEYS, names)}

    # Any start, scheduled or not (an apply that replaces the instance, a manual
    # start), pulls images and bootstraps Caddy before Grafana answers.
    just_started = launched is not None and now - launched < timedelta(minutes=GRACE_MINUTES)
    health_ok = None
    if domain and instance_state == "running" and should_run(now, schedule) and not in_grace(now, schedule) \
            and not just_started:
        check: Callable[[str], bool] = clients["http"]  # type: ignore[assignment]
        health_ok = check(f"https://{domain}/api/health")

    problems, counters = assess(now, instance_state, schedule, alarms, health_ok, state.get("counters") or {})
    messages, new_state = notify(state, problems, now, node=f"{env.get('NAME', '')} ({instance_id})")
    new_state["counters"] = counters

    if messages:
        webhook = clients["ssm"].get_parameter(Name=env["WEBHOOK_PARAMETER"], WithDecryption=True)["Parameter"]["Value"]  # type: ignore[attr-defined]
        for message in messages:
            clients["post"](webhook, message)  # type: ignore[operator]
    clients["ssm"].put_parameter(Name=env["STATE_PARAMETER"], Value=json.dumps(new_state), Type="String", Overwrite=True)  # type: ignore[attr-defined]
    return {"problems": sorted(problems), "posted": len(messages)}
