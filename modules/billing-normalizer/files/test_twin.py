import csv
import gzip
import io
import unittest
from datetime import UTC, datetime
from pathlib import Path

import pyarrow as pa

from normalizer.schema import focus_schema, runs_schema
from normalizer.twin import write_twin

FIXTURES = Path(__file__).parent / "fixtures" / "twin"
FOCUS = focus_schema(["Project", "Component", "Environment"])
RUNS = runs_schema()


def day(d, hour=0, minute=0):
    return datetime(2026, 11, d, hour, minute, tzinfo=UTC)


AWS_SOURCE = "raw/provider=aws/source=data-exports/acme/data/BILLING_PERIOD=2026-11/e1/acme-00001.snappy.parquet#v1"
AWS_COMMON = {
    "ProviderName": "AWS", "BillingAccountId": "111111111111", "BillingAccountName": None,
    "SubAccountId": "570327089884", "SubAccountName": "production", "BillingPeriodStart": day(1),
    "ChargePeriodStart": day(20), "ChargePeriodEnd": day(21), "ChargeCategory": "Usage", "ChargeClass": None,
    "RegionId": "us-east-1", "ConsumedUnit": "Hrs", "BillingCurrency": "USD", "x_Component": None,
    "x_Environment": None, "x_Serverless": None, "x_Source": AWS_SOURCE,
}
FOCUS_AWS_ROWS = [
    {**AWS_COMMON, "ServiceName": "Amazon Elastic Compute Cloud", "ServiceCategory": "Compute", "SkuId": "SKU-EC2",
     "ResourceId": "i-0abc", "ConsumedQuantity": 10.0, "ListCost": 12.5, "BilledCost": 12.5, "EffectiveCost": 12.5,
     "Tags": {"TaskId": "t1", "Project": "braveheart-trainer", "RunId": "r1"}, "x_Project": "braveheart-trainer"},
    {**AWS_COMMON, "ServiceName": "Amazon Virtual Private Cloud", "ServiceCategory": "Networking", "SkuId": "SKU-IPV4",
     "ResourceId": None, "ConsumedQuantity": 24.0, "ListCost": 0.12, "BilledCost": 0.12, "EffectiveCost": 0.12,
     "Tags": {}, "x_Project": None},
]
FOCUS_DATABRICKS_ROWS = [{
    "ProviderName": "Databricks", "BillingAccountId": "acc-1", "BillingAccountName": None, "SubAccountId": "1234567890",
    "SubAccountName": "jaws-shared", "BillingPeriodStart": day(1), "ChargePeriodStart": day(20),
    "ChargePeriodEnd": day(21), "ChargeCategory": "Usage", "ChargeClass": None, "ServiceName": "Databricks JOBS",
    "ServiceCategory": "Analytics", "SkuId": "PREMIUM_JOBS_SERVERLESS_COMPUTE_US_EAST_N_VIRGINIA", "RegionId": None,
    "ResourceId": "job-1", "ConsumedQuantity": 2.0, "ConsumedUnit": "DBU", "ListCost": 1.0, "BilledCost": 1.0,
    "EffectiveCost": 1.0, "BillingCurrency": "USD", "Tags": {"Project": "jaws"}, "x_Project": "jaws",
    "x_Component": None, "x_Environment": None, "x_Serverless": True,
    "x_Source": "raw/provider=databricks/source=system-tables/table=usage/billing_period=2026-11/run=20261121T050000Z/part-0.parquet#v1",
}]


def event(run, task, name, at, project, **fields):
    source = f"raw/provider=jaws/source=task-runs/project={project}/date=2026-11-20/{run}.{task}.{name}.json#v1"
    row = {column: None for column in RUNS.names}
    row.update(run_key=f"RunId={run};TaskId={task}", tags={"RunId": run, "TaskId": task}, event=name, at=at,
               project=project, links={}, attributes={}, x_Source=source)
    row.update(fields)
    return row


RUNS_ROWS = [
    event("r1", "t1", "started", day(20, 10), "braveheart-trainer", campaign="net-v12", kind="train",
          instance_type="g6e.xlarge", accelerators=1, market="spot", zone="use1-az4", instance_id="i-0abc",
          hourly_usd=1.07, on_demand_hourly_usd=2.7, worst_case_usd=10.8, ceiling_usd=10.0, max_hours=4.0,
          links={"run": "https://github.com/acme/trainer/actions/runs/1"}),
    event("r1", "t1", "finished", day(20, 15, 42), "braveheart-trainer", outcome="passed", exit_code=0),
    event("r2", "t2", "started", day(20, 11), "braveheart-selfplay", campaign="datagen-2026-11", kind="datagen",
          instance_type="c7g.large", accelerators=0, market="spot", zone="use1-az2", instance_id="i-0def",
          hourly_usd=0.03, on_demand_hourly_usd=0.07, worst_case_usd=0.07, ceiling_usd=5.0, max_hours=1.0),
    event("r3", "t3", "started", day(20, 12), "braveheart-selfplay", kind="datagen", instance_type="c7g.large",
          accelerators=0, market="on-demand", zone="use1-az2", instance_id="i-0ghi", hourly_usd=0.07,
          on_demand_hourly_usd=0.07),
    event("r4", "t4", "started", day(20, 9), "braveheart-trainer", kind="train", instance_type="g6e.xlarge",
          accelerators=1, market="spot", zone="use1-az4", instance_id="i-0jkl", hourly_usd=1.07,
          on_demand_hourly_usd=2.7, worst_case_usd=5.4, ceiling_usd=5.0, max_hours=2.0),
    event("r4", "t4", "swept", day(20, 13), "braveheart-trainer", reason="max hours exceeded"),
]


def text(twin: bytes) -> str:
    return gzip.decompress(twin).decode("utf-8")


class TwinTest(unittest.TestCase):
    def test_nulls_and_empty_strings_differ(self):
        schema = pa.schema([("a", pa.string()), ("b", pa.string()), ("c", pa.string())])

        body = text(write_twin([{"a": None, "b": "", "c": "x"}], schema))

        self.assertEqual(body, '"a","b","c"\n,"","x"\n')

    def test_values_are_written_as_postgres_reads_them(self):
        schema = pa.schema([("t", pa.timestamp("ms", tz="UTC")), ("b", pa.bool_()), ("m", pa.map_(pa.string(), pa.string())),
                            ("f", pa.float64()), ("i", pa.int32())])

        [_, row] = text(write_twin([{"t": day(1), "b": True, "m": {"b": "2", "a": "1"}, "f": 0.1, "i": 3}], schema)).splitlines()

        self.assertEqual(row, '"2026-11-01T00:00:00+00:00","true","{""a"": ""1"", ""b"": ""2""}","0.1","3"')

    def test_the_twin_matches_the_contract_fixtures(self):
        for name, rows, schema in (("focus-aws.csv", FOCUS_AWS_ROWS, FOCUS), ("focus-databricks.csv", FOCUS_DATABRICKS_ROWS, FOCUS),
                                   ("runs.csv", RUNS_ROWS, RUNS)):
            with self.subTest(name):
                self.assertEqual(text(write_twin(rows, schema)), (FIXTURES / name).read_text())

    def test_the_bytes_are_reproducible(self):
        self.assertEqual(write_twin(RUNS_ROWS, RUNS), write_twin(RUNS_ROWS, RUNS))

    def test_every_row_has_every_column(self):
        rows = list(csv.reader(io.StringIO(text(write_twin(RUNS_ROWS, RUNS)))))

        self.assertEqual(rows[0], RUNS.names)
        self.assertTrue(all(len(row) == len(RUNS.names) for row in rows))


if __name__ == "__main__":
    unittest.main()
