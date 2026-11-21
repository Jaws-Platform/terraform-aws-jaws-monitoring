"""Databricks system tables: find each billing period's newest snapshot and map
its usage to the normalized FOCUS table at list price.

A daily job delivers whole billing periods under the source prefix:
  table=usage/billing_period=YYYY-MM/run=<YYYYMMDDTHHMMSSZ>/part-*.parquet   system.billing.usage
  table=list_prices/run=<…>/part-*.parquet                                  system.billing.list_prices
  table=workspaces/run=<…>/part-*.parquet  (optional)                       workspace_id, workspace_name
The newest run of each wins.

Cost is usage_quantity times the matching list price (pricing.effective_list.default,
else pricing.default), matched on sku_name and cloud where
price_start_time <= usage_end_time < price_end_time, as Databricks documents it.
For a pay-as-you-go account the list price is the billed price.
"""

import re
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from decimal import Decimal

from .schema import promoted_column
from .store import ObjectInfo, Store
from .tags import promote

SERVICE_CATEGORIES: dict[str, str] = {
    **dict.fromkeys(
        ["JOBS", "DLT", "ALL_PURPOSE", "INTERACTIVE", "BASE_ENVIRONMENTS", "LAKEFLOW_CONNECT", "APPS"], "Compute"),
    **dict.fromkeys(
        ["SQL", "GENIE", "LAKEHOUSE_MONITORING", "DATA_QUALITY_MONITORING", "DATA_CLASSIFICATION",
         "PREDICTIVE_OPTIMIZATION"], "Analytics"),
    **dict.fromkeys(
        ["MODEL_SERVING", "VECTOR_SEARCH", "FOUNDATION_MODEL_TRAINING", "AGENT_EVALUATION", "AI_GATEWAY",
         "AI_RUNTIME", "AI_FUNCTIONS", "AGENT_BRICKS", "SUPERVISOR_AGENT", "FEATURE_STORE"],
        "AI and Machine Learning"),
    "DEFAULT_STORAGE": "Storage",
    **dict.fromkeys(["DATABASE", "LAKEBASE", "ONLINE_TABLES", "LAKEHOUSE_REAL_TIME"], "Databases"),
    **dict.fromkeys(["NETWORKING", "DATA_SHARING", "CLEAN_ROOM"], "Networking"),
    "FINE_GRAINED_ACCESS_CONTROL": "Security",
}

# usage_metadata fields that name the resource a charge belongs to; the first set one wins.
RESOURCE_ID_FIELDS: tuple[str, ...] = (
    "job_id", "dlt_pipeline_id", "warehouse_id", "endpoint_id", "app_id",
    "database_instance_id", "cluster_id", "instance_pool_id",
)

_USAGE = re.compile(r"/table=usage/billing_period=(\d{4}-\d{2})/run=([^/]+)/")
_TABLE = re.compile(r"/table=(list_prices|workspaces)/run=([^/]+)/")


@dataclass(frozen=True)
class DatabricksDeliveries:
    usage: dict[str, tuple[ObjectInfo, ...]]
    prices: tuple[ObjectInfo, ...]
    workspaces: tuple[ObjectInfo, ...]


def _newest(runs: dict[str, list[ObjectInfo]]) -> tuple[ObjectInfo, ...]:
    return tuple(runs[max(runs)]) if runs else ()


def latest_databricks_deliveries(store: Store, prefix: str) -> DatabricksDeliveries:
    """The newest run's objects for each usage period, and for the price and workspace tables."""
    usage: dict[str, dict[str, list[ObjectInfo]]] = {}
    tables: dict[str, dict[str, list[ObjectInfo]]] = {"list_prices": {}, "workspaces": {}}
    for info in store.list(f"{prefix}/"):
        if not info.key.endswith(".parquet"):
            continue
        if match := _USAGE.search(info.key):
            usage.setdefault(match.group(1), {}).setdefault(match.group(2), []).append(info)
        elif match := _TABLE.search(info.key):
            tables[match.group(1)].setdefault(match.group(2), []).append(info)
    return DatabricksDeliveries(
        usage={period: _newest(runs) for period, runs in sorted(usage.items())},
        prices=_newest(tables["list_prices"]),
        workspaces=_newest(tables["workspaces"]),
    )


def _utc(value: datetime | None) -> datetime | None:
    if value is None:
        return None
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)


def _day(value: date | datetime) -> date:
    return value.date() if isinstance(value, datetime) else value


def _decimal(value) -> Decimal:
    return value if isinstance(value, Decimal) else Decimal(str(value))


def _unit_price(price: Mapping) -> Decimal | None:
    pricing = price.get("pricing") or {}
    effective = (pricing.get("effective_list") or {}).get("default")
    value = effective if effective is not None else pricing.get("default")
    return None if value is None else _decimal(value)


def _match_price(row: Mapping, prices_by_sku: Mapping[str, list[Mapping]]) -> Mapping | None:
    end = _utc(row.get("usage_end_time"))
    for price in prices_by_sku.get(row.get("sku_name"), []):
        if row.get("cloud") and price.get("cloud") and row["cloud"] != price["cloud"]:
            continue
        start, stop = _utc(price.get("price_start_time")), _utc(price.get("price_end_time"))
        if end is not None and start is not None and start <= end and (stop is None or end < stop):
            return price
    return None


def _resource_id(metadata: Mapping | None) -> str | None:
    for field in RESOURCE_ID_FIELDS:
        value = (metadata or {}).get(field)
        if value:
            return str(value)
    return None


def map_databricks_rows(
    usage: Iterable[Mapping],
    prices: Sequence[Mapping],
    workspaces: Sequence[Mapping],
    *,
    account_name: str,
    workspace_names: Mapping[str, str],
    workspace_projects: Mapping[str, str],
    promoted_tags: Sequence[str],
    source: str,
) -> tuple[list[dict], int]:
    """Normalized rows for Databricks usage, and how many rows found no list price (costed at zero)."""
    prices_by_sku: dict[str, list[Mapping]] = {}
    for price in prices:
        prices_by_sku.setdefault(price.get("sku_name"), []).append(price)
    names_from_table = {str(w["workspace_id"]): w["workspace_name"] for w in workspaces if w.get("workspace_name")}

    rows, unpriced = [], 0
    for row in usage:
        workspace_id = str(row.get("workspace_id"))
        workspace_name = names_from_table.get(workspace_id) or workspace_names.get(workspace_id) or workspace_id
        quantity = _decimal(row.get("usage_quantity") or 0)
        price = _match_price(row, prices_by_sku)
        unit_price = None if price is None else _unit_price(price)
        if unit_price is None:
            unpriced += 1
            cost = 0.0
        else:
            cost = float(quantity * unit_price)

        day = _day(row["usage_date"])
        charge_start = datetime(day.year, day.month, day.day, tzinfo=UTC)
        product = row.get("billing_origin_product")
        tags = dict(row.get("custom_tags") or {})
        promoted = promote(tags, promoted_tags)
        if "Project" in promoted and promoted["Project"] is None:
            promoted["Project"] = workspace_projects.get(workspace_id) or workspace_projects.get(workspace_name)

        out = {
            "ProviderName": "Databricks",
            "BillingAccountId": row.get("account_id"),
            "BillingAccountName": account_name,
            "SubAccountId": workspace_id,
            "SubAccountName": workspace_name,
            "BillingPeriodStart": datetime(day.year, day.month, 1, tzinfo=UTC),
            "ChargePeriodStart": charge_start,
            "ChargePeriodEnd": charge_start + timedelta(days=1),
            "ChargeCategory": "Usage",
            "ChargeClass": "Correction" if row.get("record_type") in ("RETRACTION", "RESTATEMENT") else None,
            "ServiceName": f"Databricks {product}" if product else "Databricks",
            "ServiceCategory": SERVICE_CATEGORIES.get(product, "Other"),
            "SkuId": row.get("sku_name"),
            "RegionId": None,
            "ResourceId": _resource_id(row.get("usage_metadata")),
            "ConsumedQuantity": float(quantity),
            "ConsumedUnit": row.get("usage_unit"),
            "ListCost": cost,
            "BilledCost": cost,
            "EffectiveCost": cost,
            "BillingCurrency": (price or {}).get("currency_code") or "USD",
            "Tags": tags,
        }
        for tag, value in promoted.items():
            out[promoted_column(tag)] = value
        features = row.get("product_features") or {}
        out["x_Serverless"] = features.get("is_serverless")
        out["x_Source"] = source
        rows.append(out)
    return rows, unpriced
