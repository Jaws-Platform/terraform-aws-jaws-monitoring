import json
import unittest
from datetime import UTC, datetime

from fakes import FakeStore
from normalizer.aws import latest_aws_deliveries, map_aws_rows
from normalizer.schema import focus_schema

BUCKET = "acme-billing"
PREFIX = "raw/provider=aws/source=data-exports/acme-focus-daily"


def manifest(execution_id, period, files):
    return json.dumps({
        "executionId": execution_id,
        "exportArn": "arn:aws:bcm-data-exports:us-east-1:111111111111:export/acme-focus-daily-x",
        "columns": [],
        "dataFiles": [f"s3://{BUCKET}/{PREFIX}/data/BILLING_PERIOD={period}/{f}" for f in files],
        "additionalOutputFiles": [],
        "additionalInfo": {"rowCount": 1},
    }).encode()


def aws_row(**overrides):
    row = {
        "ProviderName": "AWS",
        "PublisherName": "AWS",
        "BillingAccountId": "111111111111",
        "BillingAccountName": "acme-management",
        "SubAccountId": "570327089884",
        "SubAccountName": "acme-production",
        "BillingPeriodStart": datetime(2026, 11, 1, tzinfo=UTC),
        "ChargePeriodStart": datetime(2026, 11, 20, tzinfo=UTC),
        "ChargePeriodEnd": datetime(2026, 11, 21, tzinfo=UTC),
        "ChargeCategory": "Usage",
        "ChargeClass": None,
        "ServiceName": "Amazon Elastic Compute Cloud",
        "ServiceCategory": "Compute",
        "SkuId": "SKU1",
        "RegionId": "us-east-1",
        "ResourceId": "i-0abc",
        "ConsumedQuantity": 24.0,
        "ConsumedUnit": "Hrs",
        "ListCost": 1.5,
        "BilledCost": 1.5,
        "EffectiveCost": 1.5,
        "BillingCurrency": "USD",
        "Tags": {"user:Project": "braveheart"},
        "x_ServiceCode": "AmazonEC2",
    }
    row.update(overrides)
    return row


class LatestDeliveriesTest(unittest.TestCase):
    def test_latest_delivery_per_period_comes_from_its_newest_manifest(self):
        store = FakeStore()
        store.add(f"{PREFIX}/metadata/BILLING_PERIOD=2026-11/x-Manifest.json", manifest("a", "2026-11", ["a/x-00001.snappy.parquet"]),
                  last_modified=datetime(2026, 11, 20, tzinfo=UTC))
        store.add(f"{PREFIX}/metadata/BILLING_PERIOD=2026-11/Manifest.json", manifest("b", "2026-11", ["b/x-00001.snappy.parquet"]),
                  last_modified=datetime(2026, 11, 21, tzinfo=UTC))
        store.add(f"{PREFIX}/metadata/BILLING_PERIOD=2026-10/Manifest.json", manifest("c", "2026-10", ["c/x-00001.snappy.parquet"]))
        store.add(f"{PREFIX}/data/BILLING_PERIOD=2026-11/b/x-00001.snappy.parquet", b"data")

        deliveries = latest_aws_deliveries(store, BUCKET, PREFIX)

        self.assertEqual({p: d.execution_id for p, d in deliveries.items()}, {"2026-10": "c", "2026-11": "b"})
        self.assertEqual(deliveries["2026-11"].data_keys, (f"{PREFIX}/data/BILLING_PERIOD=2026-11/b/x-00001.snappy.parquet",))

    def test_manifest_files_in_another_bucket_are_an_error(self):
        store = FakeStore()
        key = f"{PREFIX}/metadata/BILLING_PERIOD=2026-11/Manifest.json"
        body = json.loads(manifest("a", "2026-11", []))
        body["dataFiles"] = ["s3://other/x.parquet"]
        store.add(key, json.dumps(body).encode())

        with self.assertRaisesRegex(ValueError, "Manifest.json"):
            latest_aws_deliveries(store, BUCKET, PREFIX)


class MapAwsRowsTest(unittest.TestCase):
    def test_maps_focus_columns_and_promotes_tags(self):
        [row] = map_aws_rows([aws_row()], promoted_tags=["Project"], exclude_publishers=[], source="src")

        self.assertEqual(set(row), set(focus_schema(["Project"]).names))
        self.assertEqual(row["BilledCost"], 1.5)
        self.assertEqual(row["ServiceName"], "Amazon Elastic Compute Cloud")
        self.assertEqual(row["SubAccountId"], "570327089884")
        self.assertEqual(row["Tags"], {"user:Project": "braveheart"})
        self.assertEqual(row["x_Project"], "braveheart")
        self.assertIsNone(row["x_Serverless"])
        self.assertEqual(row["x_Source"], "src")

    def test_rows_from_excluded_publishers_are_dropped(self):
        rows = map_aws_rows([aws_row(PublisherName="Databricks")], promoted_tags=["Project"],
                            exclude_publishers=["Databricks"], source="src")
        self.assertEqual(rows, [])

    def test_null_tags_become_an_empty_map(self):
        [row] = map_aws_rows([aws_row(Tags=None)], promoted_tags=["Project"], exclude_publishers=[], source="src")
        self.assertEqual(row["Tags"], {})
        self.assertIsNone(row["x_Project"])


if __name__ == "__main__":
    unittest.main()
