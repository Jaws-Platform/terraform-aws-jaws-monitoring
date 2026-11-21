"""The normalized tables: FOCUS-aligned cost rows and task-run events."""

from collections.abc import Sequence

import pyarrow as pa

# Bump to rebuild every normalized object: part of every source signature.
MAPPER_VERSION = "1"

_TIMESTAMP = pa.timestamp("ms", tz="UTC")
_TAGS = pa.map_(pa.string(), pa.string())

# FOCUS 1.2 column names. One row per day x provider x account x service x
# SKU x resource x tag set.
_FOCUS_FIELDS = [
    ("ProviderName", pa.string()),
    ("BillingAccountId", pa.string()),
    ("BillingAccountName", pa.string()),
    ("SubAccountId", pa.string()),
    ("SubAccountName", pa.string()),
    ("BillingPeriodStart", _TIMESTAMP),
    ("ChargePeriodStart", _TIMESTAMP),
    ("ChargePeriodEnd", _TIMESTAMP),
    ("ChargeCategory", pa.string()),
    ("ChargeClass", pa.string()),
    ("ServiceName", pa.string()),
    ("ServiceCategory", pa.string()),
    ("SkuId", pa.string()),
    ("RegionId", pa.string()),
    ("ResourceId", pa.string()),
    ("ConsumedQuantity", pa.float64()),
    ("ConsumedUnit", pa.string()),
    ("ListCost", pa.float64()),
    ("BilledCost", pa.float64()),
    ("EffectiveCost", pa.float64()),
    ("BillingCurrency", pa.string()),
    ("Tags", _TAGS),
]

FOCUS_BASE_COLUMNS = tuple(name for name, _ in _FOCUS_FIELDS)

_RUNS_FIELDS = [
    ("run_key", pa.string()),
    ("tags", _TAGS),
    ("event", pa.string()),
    ("at", _TIMESTAMP),
    ("project", pa.string()),
    ("campaign", pa.string()),
    ("kind", pa.string()),
    ("instance_type", pa.string()),
    ("accelerators", pa.int32()),
    ("market", pa.string()),
    ("zone", pa.string()),
    ("instance_id", pa.string()),
    ("hourly_usd", pa.float64()),
    ("on_demand_hourly_usd", pa.float64()),
    ("worst_case_usd", pa.float64()),
    ("ceiling_usd", pa.float64()),
    ("max_hours", pa.float64()),
    ("outcome", pa.string()),
    ("exit_code", pa.int32()),
    ("interrupted_at", _TIMESTAMP),
    ("reason", pa.string()),
    ("links", _TAGS),
    ("attributes", _TAGS),
    ("x_Source", pa.string()),
]


def promoted_column(name: str) -> str:
    """The column a promoted tag is written to."""
    return f"x_{name}"


def focus_schema(promoted_tags: Sequence[str]) -> pa.Schema:
    """FOCUS columns, then one x_<tag> column per promoted tag, then x_Serverless and x_Source."""
    fields = [pa.field(name, kind) for name, kind in _FOCUS_FIELDS]
    fields += [pa.field(promoted_column(tag), pa.string()) for tag in promoted_tags]
    fields += [pa.field("x_Serverless", pa.bool_()), pa.field("x_Source", pa.string())]
    return pa.schema(fields)


def runs_schema() -> pa.Schema:
    """One row per task-run event (runs-1)."""
    return pa.schema([pa.field(name, kind) for name, kind in _RUNS_FIELDS])
