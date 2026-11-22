"""Tests for the watchdog Lambda (files/watchdog/watchdog.py), with fake AWS
clients and a fixed clock. Run with `python3 -m unittest discover -s files`,
and inside the Lambda runtime by tests/test-watchdog-runtime.sh."""

import json
import os
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent / "watchdog"))
import watchdog  # noqa: E402

JAWS = {"timezone": "America/Denver", "days": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"], "on": "08:00", "off": "24:00"}
WEEKDAYS = {"timezone": "America/Denver", "days": ["mon", "tue", "wed", "thu", "fri"], "on": "08:00", "off": "20:00"}


def utc(text: str) -> datetime:
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def assess(now, state="running", schedule=None, alarms=None, health=None, counters=None):
    return watchdog.assess(utc(now), state, schedule, alarms or {}, health, counters or {})


class WindowTest(unittest.TestCase):
    def test_midnight_off_means_the_end_of_the_day(self):
        # 2026-11-23 is a Monday; Denver is UTC-7 in November.
        self.assertTrue(watchdog.should_run(utc("2026-11-23T06:59:00Z"), JAWS))   # Sun 23:59
        self.assertFalse(watchdog.should_run(utc("2026-11-23T07:00:00Z"), JAWS))  # Mon 00:00

    def test_the_window_follows_daylight_saving(self):
        self.assertTrue(watchdog.should_run(utc("2026-07-15T14:30:00Z"), JAWS))   # 08:30 MDT
        self.assertTrue(watchdog.should_run(utc("2027-01-15T15:30:00Z"), JAWS))   # 08:30 MST
        self.assertFalse(watchdog.should_run(utc("2026-07-15T13:30:00Z"), JAWS))  # 07:30 MDT

    def test_days_off_are_off(self):
        self.assertFalse(watchdog.should_run(utc("2026-11-21T17:00:00Z"), WEEKDAYS))  # Sat 10:00
        self.assertTrue(watchdog.should_run(utc("2026-11-23T17:00:00Z"), WEEKDAYS))   # Mon 10:00

    def test_a_24_7_node_should_always_run(self):
        self.assertTrue(watchdog.should_run(utc("2026-11-23T09:00:00Z"), None))
        self.assertFalse(watchdog.in_grace(utc("2026-11-23T09:00:00Z"), None))

    def test_grace_follows_a_start_and_a_stop(self):
        self.assertTrue(watchdog.in_grace(utc("2026-11-23T15:10:00Z"), JAWS))   # 08:10, after the start
        self.assertFalse(watchdog.in_grace(utc("2026-11-23T15:20:00Z"), JAWS))  # 08:20
        self.assertTrue(watchdog.in_grace(utc("2026-11-23T07:05:00Z"), JAWS))   # 00:05, after the 24:00 stop


class AssessTest(unittest.TestCase):
    def test_a_24_7_node_that_is_stopped_is_critical_on_the_second_check(self):
        problems, counters = assess("2026-11-23T09:00:00Z", "stopped")
        self.assertEqual(problems, {})
        problems, counters = assess("2026-11-23T09:05:00Z", "stopped", counters=counters)
        self.assertEqual(problems["not-running"]["severity"], "critical")

    def test_one_not_running_check_is_not_critical(self):
        problems, counters = assess("2026-11-23T09:00:00Z", "stopped")
        self.assertEqual(problems, {})
        problems, counters = assess("2026-11-23T09:05:00Z", "running", counters=counters)
        self.assertEqual((problems, counters["not_running"]), ({}, 0))

    def test_a_scheduled_node_is_not_flagged_in_its_first_15_minutes(self):
        problems, counters = assess("2026-11-23T15:10:00Z", "stopped", JAWS)
        self.assertEqual((problems, counters["not_running"]), ({}, 0))

    def test_a_scheduled_node_still_stopped_after_15_minutes_is_critical(self):
        _, counters = assess("2026-11-23T15:20:00Z", "stopped", JAWS)
        problems, _ = assess("2026-11-23T15:25:00Z", "stopped", JAWS, counters=counters)
        self.assertEqual(problems["not-running"]["severity"], "critical")

    def test_a_stopped_node_in_its_off_window_is_fine(self):
        problems, _ = assess("2026-11-23T10:00:00Z", "stopped", JAWS)  # 03:00
        self.assertEqual(problems, {})

    def test_running_in_the_off_window_is_a_warning(self):
        problems, _ = assess("2026-11-23T07:20:00Z", "running", JAWS)  # 00:20
        self.assertEqual(problems["running-off-hours"]["severity"], "warning")
        problems, _ = assess("2026-11-23T07:10:00Z", "running", JAWS)  # 00:10, still stopping
        self.assertEqual(problems, {})

    def test_two_health_failures_in_a_row_are_critical(self):
        problems, counters = assess("2026-11-23T17:00:00Z", health=False)
        self.assertEqual(problems, {})
        problems, counters = assess("2026-11-23T17:05:00Z", health=True, counters=counters)
        self.assertEqual((problems, counters["health"]), ({}, 0))
        _, counters = assess("2026-11-23T17:10:00Z", health=False, counters=counters)
        problems, _ = assess("2026-11-23T17:15:00Z", health=False, counters=counters)
        self.assertEqual(problems["health"]["severity"], "critical")

    def test_a_failed_status_check_alarm_is_critical(self):
        problems, _ = assess("2026-11-23T17:00:00Z", alarms={"status-system": "ALARM", "status-instance": "OK"})
        self.assertEqual(list(problems), ["status-system"])
        self.assertEqual(problems["status-system"]["severity"], "critical")


class NotifyTest(unittest.TestCase):
    PROBLEM = {"not-running": {"severity": "critical", "title": "Monitoring node not running", "detail": "It is stopped."}}

    def test_a_problem_posts_once_repeats_after_4_hours_and_posts_when_resolved(self):
        messages, state = watchdog.notify({}, self.PROBLEM, utc("2026-11-23T09:00:00Z"), node="acme (i-1)")
        self.assertEqual(len(messages), 1)
        self.assertTrue(messages[0].startswith("🚨 [FIRING] Monitoring node not running — severity: critical"))
        self.assertIn("acme (i-1)", messages[0])
        messages, state = watchdog.notify(state, self.PROBLEM, utc("2026-11-23T12:59:00Z"), node="acme (i-1)")
        self.assertEqual(messages, [])
        messages, state = watchdog.notify(state, self.PROBLEM, utc("2026-11-23T13:00:00Z"), node="acme (i-1)")
        self.assertEqual(len(messages), 1)
        messages, state = watchdog.notify(state, {}, utc("2026-11-23T13:05:00Z"), node="acme (i-1)")
        self.assertEqual(len(messages), 1)
        self.assertTrue(messages[0].startswith("✅ [RESOLVED] Monitoring node not running"))
        self.assertEqual(state["problems"], {})


class FakeSSM:
    def __init__(self, state=None):
        self.params = {"/acme/slack/platform": "https://hooks.example/abc"}
        if state is not None:
            self.params["/acme/node/watchdog-state"] = state
        self.puts = []

    def get_parameter(self, Name, WithDecryption=False):
        if Name not in self.params:
            raise RuntimeError("ParameterNotFound")
        return {"Parameter": {"Value": self.params[Name]}}

    def put_parameter(self, Name, Value, Type, Overwrite):
        self.puts.append(Name)
        self.params[Name] = Value


class FakeEC2:
    def __init__(self, state):
        self.state = state

    def describe_instances(self, InstanceIds):
        return {"Reservations": [{"Instances": [{"InstanceId": InstanceIds[0], "State": {"Name": self.state}}]}]}


class FakeCloudWatch:
    def describe_alarms(self, AlarmNames):
        return {"MetricAlarms": [{"AlarmName": n, "StateValue": "OK"} for n in AlarmNames]}


ENV = {"NAME": "acme", "INSTANCE_ID": "i-1", "SCHEDULE": "", "DOMAIN": "", "WEBHOOK_PARAMETER": "/acme/slack/platform",
       "STATE_PARAMETER": "/acme/node/watchdog-state", "ALARMS": "acme-system-status,acme-instance-status"}


class HandlerTest(unittest.TestCase):
    def run_handler(self, ssm, state="stopped", event=None, post=None, now="2026-11-23T09:00:00Z"):
        posted = []
        clients = {"ec2": FakeEC2(state), "cloudwatch": FakeCloudWatch(), "ssm": ssm, "http": lambda url: True,
                   "post": post or (lambda url, text: posted.append((url, text))), "now": lambda: utc(now)}
        with mock.patch.dict(os.environ, ENV, clear=False):
            watchdog.handler(event or {}, None, clients)
        return posted

    def test_unreadable_state_counts_as_empty(self):
        ssm = FakeSSM(state="{not json")
        self.run_handler(ssm)
        self.assertEqual(json.loads(ssm.params["/acme/node/watchdog-state"])["counters"]["not_running"], 1)

    def test_an_sns_event_is_judged_like_a_scheduled_one(self):
        ssm = FakeSSM()
        self.run_handler(ssm)
        posted = self.run_handler(ssm, event={"Records": [{"EventSource": "aws:sns", "Sns": {"Message": "{}"}}]},
                                  now="2026-11-23T09:05:00Z")
        self.assertEqual(len(posted), 1)
        self.assertEqual(posted[0][0], "https://hooks.example/abc")
        self.assertIn("Monitoring node not running", posted[0][1])

    def test_a_failed_post_leaves_the_state_unchanged(self):
        ssm = FakeSSM()
        self.run_handler(ssm)
        before = ssm.params["/acme/node/watchdog-state"]

        def fail(url, text):
            raise OSError("slack is down")

        with self.assertRaises(OSError):
            self.run_handler(ssm, post=fail, now="2026-11-23T09:05:00Z")
        self.assertEqual(ssm.params["/acme/node/watchdog-state"], before)


if __name__ == "__main__":
    unittest.main()
