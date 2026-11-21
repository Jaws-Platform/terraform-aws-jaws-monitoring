import copy
import unittest
from datetime import UTC, datetime

from fakes import FakeStore
from normalizer.runs import flatten_event, records_by_month
from normalizer.schema import runs_schema

STARTED = {
    "schema": "runs-1",
    "event": "started",
    "at": "2026-11-24T21:10:03Z",
    "tags": {"RunId": "123456-1", "TaskId": "net-v12"},
    "project": "braveheart-trainer",
    "campaign": "net-v12",
    "kind": "train",
    "instance": {"type": "g6e.xlarge", "accelerators": 1, "market": "spot", "zone": "use1-az4", "id": "i-0abc"},
    "prices": {"hourly_usd": 1.07, "on_demand_hourly_usd": 1.861, "worst_case_usd": 11.17, "ceiling_usd": 50, "max_hours": 6},
    "outcome": None,
    "exit_code": None,
    "interrupted_at": None,
    "reason": None,
    "links": {"run": "https://github.com/acme/x/actions/runs/123456/attempts/1"},
    "attributes": {"profile": "gpu"},
}

JOIN = ["RunId", "TaskId"]


class RecordsByMonthTest(unittest.TestCase):
    def test_records_group_by_the_month_of_their_date_folder(self):
        store = FakeStore()
        store.add("raw/provider=acme/source=task-runs/project=a/date=2026-11-30/1.net.started.json", b"{}")
        store.add("raw/provider=acme/source=task-runs/project=a/date=2026-12-01/1.net.finished.json", b"{}")
        store.add("raw/provider=acme/source=task-runs/project=a/README.json", b"{}")
        store.add("raw/provider=acme/source=task-runs/project=a/date=2026-12-01/notes.txt", b"x")

        months = records_by_month(store, ["raw/provider=acme/source=task-runs"])

        self.assertEqual(sorted(months), ["2026-11", "2026-12"])
        self.assertEqual([i.key for i in months["2026-12"]],
                         ["raw/provider=acme/source=task-runs/project=a/date=2026-12-01/1.net.finished.json"])


class FlattenEventTest(unittest.TestCase):
    def test_flattens_a_started_event(self):
        row = flatten_event(STARTED, join_tags=JOIN, source="src")

        self.assertEqual(set(row), set(runs_schema().names))
        self.assertEqual(row["run_key"], "RunId=123456-1;TaskId=net-v12")
        self.assertEqual(row["tags"], {"RunId": "123456-1", "TaskId": "net-v12"})
        self.assertEqual(row["event"], "started")
        self.assertEqual(row["at"], datetime(2026, 11, 24, 21, 10, 3, tzinfo=UTC))
        self.assertEqual(row["instance_type"], "g6e.xlarge")
        self.assertEqual(row["accelerators"], 1)
        self.assertEqual(row["hourly_usd"], 1.07)
        self.assertEqual(row["ceiling_usd"], 50.0)
        self.assertEqual(row["campaign"], "net-v12")
        self.assertEqual(row["links"], {"run": "https://github.com/acme/x/actions/runs/123456/attempts/1"})
        self.assertEqual(row["attributes"], {"profile": "gpu"})
        self.assertEqual(row["x_Source"], "src")

    def test_run_key_follows_the_join_tag_order(self):
        row = flatten_event(STARTED, join_tags=["TaskId", "RunId"], source="src")
        self.assertEqual(row["run_key"], "TaskId=net-v12;RunId=123456-1")

    def test_invalid_records_are_skipped_and_reported(self):
        def broken(**changes):
            record = copy.deepcopy(STARTED)
            record.update(changes)
            return record

        no_run_id = copy.deepcopy(STARTED)
        del no_run_id["tags"]["RunId"]
        for record in [broken(schema="runs-2"), broken(event="paused"), no_run_id, broken(project=" "), broken(at="yesterday")]:
            with self.subTest(record=record), self.assertRaises(ValueError):
                flatten_event(record, join_tags=JOIN, source="src")


if __name__ == "__main__":
    unittest.main()
