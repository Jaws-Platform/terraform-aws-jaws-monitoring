import unittest
from datetime import UTC, date, datetime
from decimal import Decimal

from fakes import FakeStore
from normalizer.databricks import latest_databricks_deliveries, map_databricks_rows

PREFIX = "raw/provider=databricks/source=system-tables"


def usage(**overrides):
    row = {
        "record_id": "r1",
        "account_id": "acct-1",
        "workspace_id": "111",
        "sku_name": "PREMIUM_JOBS_SERVERLESS_COMPUTE_US_EAST_N_VIRGINIA",
        "cloud": "AWS",
        "usage_start_time": datetime(2026, 11, 20, 5, tzinfo=UTC),
        "usage_end_time": datetime(2026, 11, 20, 6, tzinfo=UTC),
        "usage_date": date(2026, 11, 20),
        "custom_tags": {},
        "usage_unit": "DBU",
        "usage_quantity": Decimal("2.5"),
        "usage_metadata": {"job_id": None, "cluster_id": None},
        "record_type": "ORIGINAL",
        "billing_origin_product": "JOBS",
        "product_features": {"is_serverless": True},
    }
    row.update(overrides)
    return row


def price(sku="PREMIUM_JOBS_SERVERLESS_COMPUTE_US_EAST_N_VIRGINIA", value="0.35", start=datetime(2026, 1, 1, tzinfo=UTC), end=None):
    return {
        "price_start_time": start,
        "price_end_time": end,
        "account_id": "acct-1",
        "sku_name": sku,
        "cloud": "AWS",
        "currency_code": "USD",
        "usage_unit": "DBU",
        "pricing": {"default": Decimal(value), "promotional": {"default": None}, "effective_list": {"default": Decimal(value)}},
    }


def mapped(rows, prices=None, workspaces=(), workspace_names=None, workspace_projects=None):
    return map_databricks_rows(
        rows,
        [price()] if prices is None else prices,
        list(workspaces),
        account_name="Databricks",
        workspace_names=workspace_names or {},
        workspace_projects=workspace_projects or {},
        promoted_tags=["Project"],
        source="src",
    )


class LatestDeliveriesTest(unittest.TestCase):
    def test_newest_run_per_period_and_table(self):
        store = FakeStore()
        store.add(f"{PREFIX}/table=usage/billing_period=2026-11/run=20261120T060000Z/part-0.parquet", b"old")
        store.add(f"{PREFIX}/table=usage/billing_period=2026-11/run=20261121T060000Z/part-0.parquet", b"new")
        store.add(f"{PREFIX}/table=usage/billing_period=2026-10/run=20261121T060000Z/part-0.parquet", b"oct")
        store.add(f"{PREFIX}/table=list_prices/run=20261120T060000Z/part-0.parquet", b"p1")
        store.add(f"{PREFIX}/table=list_prices/run=20261121T060000Z/part-0.parquet", b"p2")

        deliveries = latest_databricks_deliveries(store, PREFIX)

        self.assertEqual(sorted(deliveries.usage), ["2026-10", "2026-11"])
        self.assertEqual([i.key for i in deliveries.usage["2026-11"]],
                         [f"{PREFIX}/table=usage/billing_period=2026-11/run=20261121T060000Z/part-0.parquet"])
        self.assertEqual([i.key for i in deliveries.prices], [f"{PREFIX}/table=list_prices/run=20261121T060000Z/part-0.parquet"])
        self.assertEqual(deliveries.workspaces, ())


class MapDatabricksRowsTest(unittest.TestCase):
    def test_cost_is_quantity_times_the_effective_list_price(self):
        rows, unpriced = mapped([usage()])
        self.assertEqual(unpriced, 0)
        self.assertAlmostEqual(rows[0]["BilledCost"], 0.875)
        self.assertEqual(rows[0]["BilledCost"], rows[0]["ListCost"])
        self.assertEqual(rows[0]["BilledCost"], rows[0]["EffectiveCost"])
        self.assertEqual(rows[0]["BillingCurrency"], "USD")
        self.assertEqual(rows[0]["ConsumedQuantity"], 2.5)
        self.assertEqual(rows[0]["ConsumedUnit"], "DBU")

    def test_price_window_uses_usage_end_time(self):
        prices = [
            price(value="0.30", start=datetime(2026, 11, 1, tzinfo=UTC), end=datetime(2026, 11, 15, tzinfo=UTC)),
            price(value="0.40", start=datetime(2026, 11, 15, tzinfo=UTC)),
        ]
        rows, _ = mapped([
            usage(usage_quantity=Decimal("1"), usage_end_time=datetime(2026, 11, 15, tzinfo=UTC)),
            usage(usage_quantity=Decimal("1"), usage_end_time=datetime(2026, 11, 14, 23, tzinfo=UTC)),
        ], prices=prices)
        self.assertAlmostEqual(rows[0]["BilledCost"], 0.40)
        self.assertAlmostEqual(rows[1]["BilledCost"], 0.30)

    def test_retractions_and_restatements_are_corrections(self):
        rows, _ = mapped([
            usage(record_type="RETRACTION", usage_quantity=Decimal("-2")),
            usage(record_type="RESTATEMENT"),
            usage(record_type="ORIGINAL"),
        ])
        self.assertEqual([r["ChargeClass"] for r in rows], ["Correction", "Correction", None])
        self.assertAlmostEqual(rows[0]["BilledCost"], -0.70)

    def test_unpriced_usage_costs_zero_and_is_reported(self):
        rows, unpriced = mapped([usage(sku_name="NEW_SKU")])
        self.assertEqual(unpriced, 1)
        self.assertEqual(rows[0]["BilledCost"], 0.0)
        self.assertEqual(rows[0]["SkuId"], "NEW_SKU")

    def test_project_falls_back_to_the_workspace(self):
        rows, _ = mapped([usage(), usage(custom_tags={"Project": "own"})], workspace_projects={"111": "braveheart"})
        self.assertEqual([r["x_Project"] for r in rows], ["braveheart", "own"])

    def test_workspace_name_comes_from_the_table_then_the_input_then_the_id(self):
        table = [{"workspace_id": "111", "workspace_name": "braveheart-prod"}]
        rows, _ = mapped([usage(), usage(workspace_id="222"), usage(workspace_id="333")],
                         workspaces=table, workspace_names={"111": "ignored", "222": "jaws-shared"})
        self.assertEqual([r["SubAccountName"] for r in rows], ["braveheart-prod", "jaws-shared", "333"])
        self.assertEqual([r["SubAccountId"] for r in rows], ["111", "222", "333"])

    def test_service_name_category_resource_and_serverless(self):
        [row], _ = mapped([usage(usage_metadata={"job_id": "42", "cluster_id": "c"})])
        self.assertEqual(row["ProviderName"], "Databricks")
        self.assertEqual(row["BillingAccountId"], "acct-1")
        self.assertEqual(row["BillingAccountName"], "Databricks")
        self.assertEqual(row["ServiceName"], "Databricks JOBS")
        self.assertEqual(row["ServiceCategory"], "Compute")
        self.assertEqual(row["ChargeCategory"], "Usage")
        self.assertEqual(row["ResourceId"], "42")
        self.assertIs(row["x_Serverless"], True)
        self.assertIsNone(row["RegionId"])
        self.assertEqual(row["ChargePeriodStart"], datetime(2026, 11, 20, tzinfo=UTC))
        self.assertEqual(row["ChargePeriodEnd"], datetime(2026, 11, 21, tzinfo=UTC))
        self.assertEqual(row["BillingPeriodStart"], datetime(2026, 11, 1, tzinfo=UTC))
        self.assertEqual(row["x_Source"], "src")


if __name__ == "__main__":
    unittest.main()
