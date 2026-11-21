import unittest
from datetime import UTC, datetime

import pyarrow as pa

from normalizer.parquet import read_rows, write_rows
from normalizer.schema import focus_schema, runs_schema


def focus_row(**overrides):
    row = {name: None for name in focus_schema(["Project"]).names}
    row.update(
        ProviderName="AWS",
        BillingAccountId="650503560686",
        SubAccountId="570327089884",
        BillingPeriodStart=datetime(2026, 11, 1, tzinfo=UTC),
        ChargePeriodStart=datetime(2026, 11, 1, tzinfo=UTC),
        ChargePeriodEnd=datetime(2026, 11, 2, tzinfo=UTC),
        ChargeCategory="Usage",
        ServiceName="Amazon Simple Storage Service",
        ConsumedQuantity=1.0,
        ListCost=0.25,
        BilledCost=0.25,
        EffectiveCost=0.25,
        BillingCurrency="USD",
        Tags={"Project": "a"},
        x_Project="a",
        x_Source="src",
    )
    row.update(overrides)
    return row


class ParquetTest(unittest.TestCase):
    def test_round_trip_preserves_maps_and_utc_timestamps(self):
        row = focus_row()
        schema = focus_schema(["Project"])
        self.assertEqual(read_rows(write_rows([row], schema)), [row])

    def test_schema_lists_focus_columns_then_promoted_then_extensions(self):
        names = focus_schema(["Project", "Component"]).names
        self.assertEqual(names[:3], ["ProviderName", "BillingAccountId", "BillingAccountName"])
        self.assertEqual(names[-4:], ["x_Project", "x_Component", "x_Serverless", "x_Source"])

    def test_read_rows_reads_only_the_requested_columns_that_exist(self):
        schema = pa.schema([("a", pa.string()), ("b", pa.float64()), ("c", pa.map_(pa.string(), pa.string()))])
        body = write_rows([{"a": "x", "b": 1.0, "c": {"k": "v"}}], schema)
        self.assertEqual(read_rows(body, columns=["a", "c", "missing"]), [{"a": "x", "c": {"k": "v"}}])

    def test_runs_schema_has_the_event_columns(self):
        self.assertEqual(runs_schema().names[:4], ["run_key", "tags", "event", "at"])


if __name__ == "__main__":
    unittest.main()
