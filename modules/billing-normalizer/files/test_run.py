import csv
import gzip
import io
import json
import unittest
from datetime import UTC, date, datetime, timedelta
from decimal import Decimal
from unittest import mock

import pyarrow as pa

from fakes import FakeStore, parquet_bytes
from normalizer.config import AwsConfig, Config, DatabricksConfig, RunsConfig, load_config
from normalizer.parquet import read_rows
from normalizer.run import NormalizeError, run

BUCKET = "acme-billing"
AWS = "raw/provider=aws/source=data-exports/acme-focus-daily"
DATABRICKS = "raw/provider=databricks/source=system-tables"
RUNS = "raw/provider=acme/source=task-runs"
NOW = datetime(2026, 11, 21, 12, 0, tzinfo=UTC)

AWS_KEY = "normalized/schema=focus-1.2/provider=aws/billing_period=2026-11/data.parquet"
DATABRICKS_KEY = "normalized/schema=focus-1.2/provider=databricks/billing_period=2026-11/data.parquet"
RUNS_KEY = "normalized/schema=runs-1/event_month=2026-11/data.parquet"
RECORDS = ["normalized/_runs/20261121T120000Z.json", "normalized/_runs/latest.json"]


def twin(key):
    return key.replace("data.parquet", "data.csv.gz")

_TS = pa.timestamp("ms", tz="UTC")
_MAP = pa.map_(pa.string(), pa.string())
AWS_FIXTURE = pa.schema([
    ("ProviderName", pa.string()), ("PublisherName", pa.string()), ("BillingAccountId", pa.string()),
    ("SubAccountId", pa.string()), ("BillingPeriodStart", _TS), ("ChargePeriodStart", _TS), ("ChargePeriodEnd", _TS),
    ("ChargeCategory", pa.string()), ("ServiceName", pa.string()), ("BilledCost", pa.float64()),
    ("ListCost", pa.float64()), ("EffectiveCost", pa.float64()), ("BillingCurrency", pa.string()), ("Tags", _MAP),
])
USAGE_FIXTURE = pa.schema([
    ("account_id", pa.string()), ("workspace_id", pa.string()), ("sku_name", pa.string()), ("cloud", pa.string()),
    ("usage_end_time", _TS), ("usage_date", pa.date32()), ("custom_tags", _MAP), ("usage_unit", pa.string()),
    ("usage_quantity", pa.decimal128(38, 18)), ("record_type", pa.string()), ("billing_origin_product", pa.string()),
    ("product_features", pa.struct([("is_serverless", pa.bool_())])),
])
PRICES_FIXTURE = pa.schema([
    ("price_start_time", _TS), ("price_end_time", _TS), ("sku_name", pa.string()), ("cloud", pa.string()),
    ("currency_code", pa.string()), ("usage_unit", pa.string()),
    ("pricing", pa.struct([("default", pa.decimal128(38, 18)), ("effective_list", pa.struct([("default", pa.decimal128(38, 18))]))])),
])

CONFIG = Config(
    bucket=BUCKET,
    normalized_prefix="normalized",
    promoted_tags=("Project",),
    aws=AwsConfig(delivery_prefix=AWS, exclude_publishers=()),
    databricks=DatabricksConfig(prefix=DATABRICKS, account_name="Databricks", workspace_names={}, workspace_projects={}),
    runs=RunsConfig(prefixes=(RUNS,), join_tags=("RunId", "TaskId")),
)


def add_aws_delivery(store, execution_id, cost=1.5, last_modified=None, folder="BILLING_PERIOD"):
    data = f"{AWS}/data/{folder}=2026-11/20261121T000000-{execution_id}/acme-focus-daily-00001.snappy.parquet"
    store.add(data, parquet_bytes([{
        "ProviderName": "AWS", "PublisherName": "AWS", "BillingAccountId": "111111111111", "SubAccountId": "222222222222",
        "BillingPeriodStart": datetime(2026, 11, 1, tzinfo=UTC), "ChargePeriodStart": datetime(2026, 11, 20, tzinfo=UTC),
        "ChargePeriodEnd": datetime(2026, 11, 21, tzinfo=UTC), "ChargeCategory": "Usage", "ServiceName": "Amazon S3",
        "BilledCost": cost, "ListCost": cost, "EffectiveCost": cost, "BillingCurrency": "USD",
        "Tags": [("user:Project", "braveheart")],
    }], AWS_FIXTURE))
    manifest = {"executionId": execution_id, "dataFiles": [f"s3://{BUCKET}/{data}"]}
    store.add(f"{AWS}/metadata/{folder}=2026-11/Manifest.json", json.dumps(manifest).encode(),
              last_modified=last_modified)


def add_usage(store, sku="JOBS_SKU", period="2026-11"):
    store.add(f"{DATABRICKS}/table=usage/billing_period={period}/run=20261121T060000Z/part-0.parquet", parquet_bytes([{
        "account_id": "acct-1", "workspace_id": "111", "sku_name": sku, "cloud": "AWS",
        "usage_end_time": datetime(2026, 11, 20, 6, tzinfo=UTC), "usage_date": date(2026, 11, 20),
        "custom_tags": [("Project", "braveheart")], "usage_unit": "DBU", "usage_quantity": Decimal("2"),
        "record_type": "ORIGINAL", "billing_origin_product": "JOBS", "product_features": {"is_serverless": True},
    }], USAGE_FIXTURE))


def add_record(store, date_folder, name, body):
    store.add(f"{RUNS}/project=braveheart-trainer/date={date_folder}/{name}.json",
              body if isinstance(body, bytes) else json.dumps(body).encode())


def started(run_id, at="2026-11-20T10:00:00Z", **changes):
    record = {"schema": "runs-1", "event": "started", "at": at,
              "tags": {"RunId": run_id, "TaskId": "net"}, "project": "braveheart-trainer"}
    record.update(changes)
    return record


def seeded_store():
    store = FakeStore()
    add_aws_delivery(store, "e1")
    add_usage(store)
    store.add(f"{DATABRICKS}/table=list_prices/run=20261121T060000Z/part-0.parquet", parquet_bytes([{
        "price_start_time": datetime(2026, 1, 1, tzinfo=UTC), "price_end_time": None, "sku_name": "JOBS_SKU",
        "cloud": "AWS", "currency_code": "USD", "usage_unit": "DBU",
        "pricing": {"default": Decimal("0.5"), "effective_list": {"default": Decimal("0.5")}},
    }], PRICES_FIXTURE))
    add_record(store, "2026-11-20", "123-1.net.started", started("123-1"))
    return store


class RunTest(unittest.TestCase):
    def test_first_run_builds_every_output_and_writes_a_run_record(self):
        store = seeded_store()

        record = run(store, CONFIG, NOW)

        # Runs first: the small, time-critical event table is written before the cost tables.
        self.assertEqual(store.puts, [twin(RUNS_KEY), RUNS_KEY, twin(AWS_KEY), AWS_KEY,
                                      twin(DATABRICKS_KEY), DATABRICKS_KEY, *RECORDS])
        self.assertEqual(record["status"], "ok")
        self.assertEqual([(o["key"], o["rebuilt"]) for o in record["outputs"]],
                         [(RUNS_KEY, True), (AWS_KEY, True), (DATABRICKS_KEY, True)])
        for key in (AWS_KEY, DATABRICKS_KEY, RUNS_KEY):
            self.assertTrue(store.metadata(key)["source-signature"])
        self.assertEqual(json.loads(store.get(RECORDS[1])), record)
        [aws_row] = read_rows(store.get(AWS_KEY))
        self.assertEqual((aws_row["BilledCost"], aws_row["x_Project"]), (1.5, "braveheart"))
        [databricks_row] = read_rows(store.get(DATABRICKS_KEY))
        self.assertAlmostEqual(databricks_row["BilledCost"], 1.0)
        self.assertEqual(record["outputs"][2]["billed_cost"], 1.0)

    def test_each_rebuilt_output_has_its_twin(self):
        store = seeded_store()

        run(store, CONFIG, NOW)

        for key in (RUNS_KEY, AWS_KEY, DATABRICKS_KEY):
            twin = key.replace("data.parquet", "data.csv.gz")
            with self.subTest(key):
                self.assertEqual(store.metadata(twin), store.metadata(key))
                rows = list(csv.reader(io.StringIO(gzip.decompress(store.get(twin)).decode())))
                self.assertEqual(len(rows) - 1, len(read_rows(store.get(key))))
                # The twin goes first, so a Parquet signature only ever marks a complete output.
                self.assertLess(store.puts.index(twin), store.puts.index(key))

    def test_a_second_run_without_new_deliveries_rewrites_nothing(self):
        store = seeded_store()
        run(store, CONFIG, NOW)
        store.puts.clear()

        record = run(store, CONFIG, NOW + timedelta(hours=1))

        self.assertEqual(store.puts, ["normalized/_runs/20261121T130000Z.json", "normalized/_runs/latest.json"])
        self.assertEqual([o["rebuilt"] for o in record["outputs"]], [False, False, False])

    def test_a_new_aws_execution_rebuilds_only_that_period(self):
        store = seeded_store()
        run(store, CONFIG, NOW)
        add_aws_delivery(store, "e2", cost=2.0, last_modified=NOW + timedelta(minutes=30))
        store.puts.clear()

        run(store, CONFIG, NOW + timedelta(hours=1))

        self.assertEqual(store.puts[:2], [twin(AWS_KEY), AWS_KEY])
        self.assertNotIn(DATABRICKS_KEY, store.puts)
        self.assertNotIn(RUNS_KEY, store.puts)
        self.assertNotIn(RUNS_KEY, store.puts)
        self.assertEqual(read_rows(store.get(AWS_KEY))[0]["BilledCost"], 2.0)

    def test_a_mapper_version_change_rebuilds_everything(self):
        store = seeded_store()
        run(store, CONFIG, NOW)
        store.puts.clear()

        with mock.patch("normalizer.schema.MAPPER_VERSION", "3"):
            run(store, CONFIG, NOW + timedelta(hours=1))

        self.assertEqual(store.puts[:6], [twin(RUNS_KEY), RUNS_KEY, twin(AWS_KEY), AWS_KEY, twin(DATABRICKS_KEY), DATABRICKS_KEY])

    def test_empty_sources_write_only_a_run_record(self):
        store = FakeStore()

        record = run(store, CONFIG, NOW)

        self.assertEqual(store.puts, RECORDS)
        self.assertEqual((record["status"], record["outputs"], record["errors"]), ("ok", [], []))

    def test_a_lowercase_aws_delivery_is_normalized(self):
        store = FakeStore()
        add_aws_delivery(store, "e1", folder="billing_period")

        record = run(store, CONFIG, NOW)

        self.assertIn(AWS_KEY, store.puts)
        self.assertEqual((record["status"], record["errors"], record["warnings"]), ("ok", [], []))

    def test_an_aws_folder_layout_without_billing_periods_is_a_warning(self):
        store = FakeStore()
        store.add(f"{AWS}/metadata/period=2026-11/acme-focus-daily-Manifest.json", b"{}")

        record = run(store, CONFIG, NOW)

        self.assertEqual((record["status"], record["outputs"], record["errors"]), ("ok", [], []))
        self.assertEqual(record["warnings"], [
            f"aws: no billing-period manifest matched under {AWS}/metadata/ (1 object there); check the export's folder layout",
        ])

    def test_one_provider_failing_still_builds_the_others_and_raises(self):
        store = seeded_store()
        store.add(f"{DATABRICKS}/table=usage/billing_period=2026-11/run=20261121T060000Z/part-0.parquet", b"not parquet")

        with self.assertRaises(NormalizeError):
            run(store, CONFIG, NOW)

        self.assertIn(AWS_KEY, store.puts)
        self.assertIn(RUNS_KEY, store.puts)
        self.assertNotIn(DATABRICKS_KEY, store.puts)
        latest = json.loads(store.get("normalized/_runs/latest.json"))
        self.assertEqual(latest["status"], "error")
        self.assertEqual(len(latest["errors"]), 1)
        self.assertTrue(latest["errors"][0].startswith("databricks 2026-11: "))

    def test_malformed_run_records_are_skipped_and_the_rest_written(self):
        store = seeded_store()
        add_record(store, "2026-10-05", "bad-list", b"[]")
        add_record(store, "2026-10-05", "bad-tags", started("9-1", at="2026-10-05T10:00:00Z", tags=[]))
        add_record(store, "2026-10-05", "bad-int", started("9-2", at="2026-10-05T10:00:00Z",
                                                          instance={"accelerators": 2 ** 40}))
        add_record(store, "2026-10-05", "good", started("9-3", at="2026-10-05T10:00:00Z"))

        record = run(store, CONFIG, NOW)

        october = "normalized/schema=runs-1/event_month=2026-10/data.parquet"
        self.assertEqual(record["status"], "ok")
        self.assertEqual([row["run_key"] for row in read_rows(store.get(october))], ["RunId=9-3;TaskId=net"])
        self.assertIn(RUNS_KEY, store.puts)
        self.assertEqual(len([w for w in record["warnings"] if w.startswith("runs: ")]), 3)

    def test_a_bad_old_period_does_not_block_the_current_one(self):
        cases = {
            "manifest in another bucket": lambda store: store.add(
                f"{AWS}/metadata/BILLING_PERIOD=2026-10/Manifest.json",
                json.dumps({"executionId": "x", "dataFiles": ["s3://other/x.parquet"]}).encode()),
            "corrupt data file": lambda store: (
                store.add(f"{AWS}/data/BILLING_PERIOD=2026-10/x/acme-focus-daily-00001.snappy.parquet", b"not parquet"),
                store.add(f"{AWS}/metadata/BILLING_PERIOD=2026-10/Manifest.json", json.dumps({
                    "executionId": "x",
                    "dataFiles": [f"s3://{BUCKET}/{AWS}/data/BILLING_PERIOD=2026-10/x/acme-focus-daily-00001.snappy.parquet"],
                }).encode())),
        }
        for name, break_october in cases.items():
            with self.subTest(name):
                store = seeded_store()
                break_october(store)

                with self.assertRaises(NormalizeError):
                    run(store, CONFIG, NOW)

                self.assertIn(AWS_KEY, store.puts)
                latest = json.loads(store.get("normalized/_runs/latest.json"))
                self.assertEqual([e.split(":")[0] for e in latest["errors"]], ["aws 2026-10"])

        store = seeded_store()
        store.add(f"{DATABRICKS}/table=usage/billing_period=2026-10/run=20261121T060000Z/part-0.parquet", b"not parquet")
        with self.assertRaises(NormalizeError):
            run(store, CONFIG, NOW)
        self.assertIn(DATABRICKS_KEY, store.puts)

    def test_warnings_persist_while_their_output_is_unchanged(self):
        store = seeded_store()
        add_usage(store, sku="NEW_SKU")
        add_record(store, "2026-11-20", "broken", b"{not json")

        first = run(store, CONFIG, NOW)
        second = run(store, CONFIG, NOW + timedelta(hours=1))

        for record in (first, second):
            self.assertIn("databricks 2026-11: 1 rows have no list price", record["warnings"])
            self.assertEqual(len([w for w in record["warnings"] if w.startswith("runs: ")]), 1)
        self.assertEqual([o["rebuilt"] for o in second["outputs"]], [False, False, False])


class LoadConfigTest(unittest.TestCase):
    def test_load_config_reads_the_rendered_json(self):
        rendered = json.dumps({
            "bucket": BUCKET,
            "normalized_prefix": "normalized",
            "promoted_tags": ["Project", "Component"],
            "aws": {"delivery_prefix": AWS, "exclude_publishers": ["Databricks"]},
            "databricks": {"prefix": DATABRICKS, "account_name": "Databricks", "workspace_names": {},
                           "workspace_projects": {"jaws-shared": "jaws"}},
            "runs": {"prefixes": [RUNS], "join_tags": ["RunId", "TaskId"]},
        })
        config = load_config(rendered)
        self.assertEqual(config.promoted_tags, ("Project", "Component"))
        self.assertEqual(config.aws, AwsConfig(delivery_prefix=AWS, exclude_publishers=("Databricks",)))
        self.assertEqual(config.databricks.workspace_projects, {"jaws-shared": "jaws"})
        self.assertEqual(config.runs, RunsConfig(prefixes=(RUNS,), join_tags=("RunId", "TaskId")))

        only_aws = load_config(json.dumps({"bucket": BUCKET, "normalized_prefix": "normalized", "promoted_tags": [],
                                           "aws": {"delivery_prefix": AWS, "exclude_publishers": []},
                                           "databricks": None, "runs": None}))
        self.assertIsNone(only_aws.databricks)
        self.assertIsNone(only_aws.runs)


if __name__ == "__main__":
    unittest.main()
