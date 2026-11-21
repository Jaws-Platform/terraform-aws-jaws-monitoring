"""One normalizer run: rebuild every output whose sources changed, then record the run.

An output is one (provider, billing period) of the FOCUS table, or one event
month of the runs table. It is rebuilt only when its source signature changes:
the sha256 of MAPPER_VERSION, the provider's configuration, the promoted tags
and the identities of its source objects. The signature is kept on the output
as the S3 user metadata `source-signature`.

Each provider runs on its own: one that fails is reported and the others are
still built. The run record is always written, to _runs/<time>.json and
_runs/latest.json, and the run then raises if anything failed.
"""

import dataclasses
import hashlib
import json
from collections.abc import Callable
from datetime import UTC, datetime

import pyarrow as pa

from . import schema
from .aws import latest_aws_deliveries, map_aws_rows
from .config import Config
from .databricks import latest_databricks_deliveries, map_databricks_rows
from .parquet import read_rows, write_rows
from .runs import flatten_event, records_by_month
from .store import Store

PARQUET = "application/vnd.apache.parquet"


class NormalizeError(RuntimeError):
    """At least one provider failed; the run record says which."""


def _iso(moment: datetime) -> str:
    return moment.astimezone(UTC).isoformat().replace("+00:00", "Z")


def _fingerprint(provider_config) -> object:
    return dataclasses.asdict(provider_config)


def _signature(config: Config, provider_config, parts: list[str]) -> str:
    payload = json.dumps(
        [schema.MAPPER_VERSION, _fingerprint(provider_config), list(config.promoted_tags), sorted(parts)],
        sort_keys=True, default=list,
    )
    return hashlib.sha256(payload.encode()).hexdigest()


def _output(
    store: Store,
    record: dict,
    *,
    key: str,
    provider: str,
    period: str,
    signature: str,
    build: Callable[[], tuple[list[dict], pa.Schema]],
) -> None:
    current = store.metadata(key)
    if current is not None and current.get("source-signature") == signature:
        record["outputs"].append(
            {"key": key, "provider": provider, "period": period, "rebuilt": False, "rows": None, "billed_cost": None})
        return
    rows, table_schema = build()
    store.put(key, write_rows(rows, table_schema), metadata={"source-signature": signature}, content_type=PARQUET)
    billed = round(sum(row.get("BilledCost") or 0.0 for row in rows), 6) if "BilledCost" in table_schema.names else None
    record["outputs"].append(
        {"key": key, "provider": provider, "period": period, "rebuilt": True, "rows": len(rows), "billed_cost": billed})


def _focus_key(config: Config, provider: str, period: str) -> str:
    return f"{config.normalized_prefix}/schema=focus-1.2/provider={provider}/billing_period={period}/data.parquet"


def _aws(store: Store, config: Config, record: dict) -> None:
    aws = config.aws
    for period, delivery in latest_aws_deliveries(store, config.bucket, aws.delivery_prefix).items():
        def build(delivery=delivery):
            rows = []
            for data_key in delivery.data_keys:
                rows.extend(read_rows(store.get(data_key)))
            mapped = map_aws_rows(rows, promoted_tags=config.promoted_tags, exclude_publishers=aws.exclude_publishers,
                                  source=f"aws:{delivery.execution_id}")
            return mapped, schema.focus_schema(config.promoted_tags)

        _output(store, record, key=_focus_key(config, "aws", period), provider="aws", period=period,
                signature=_signature(config, aws, [delivery.execution_id, *delivery.data_keys]), build=build)


def _databricks(store: Store, config: Config, record: dict) -> None:
    databricks = config.databricks
    deliveries = latest_databricks_deliveries(store, databricks.prefix)
    shared = [info.etag for info in deliveries.prices + deliveries.workspaces]
    tables: dict[str, list[dict]] = {}

    def table(name: str, infos) -> list[dict]:
        if name not in tables:
            tables[name] = [row for info in infos for row in read_rows(store.get(info.key))]
        return tables[name]

    for period, usage in deliveries.usage.items():
        def build(period=period, usage=usage):
            rows = [row for info in usage for row in read_rows(store.get(info.key))]
            mapped, unpriced = map_databricks_rows(
                rows, table("prices", deliveries.prices), table("workspaces", deliveries.workspaces),
                account_name=databricks.account_name, workspace_names=databricks.workspace_names,
                workspace_projects=databricks.workspace_projects, promoted_tags=config.promoted_tags,
                source=usage[0].key)
            if unpriced:
                record["warnings"].append(f"databricks {period}: {unpriced} rows have no list price")
            return mapped, schema.focus_schema(config.promoted_tags)

        _output(store, record, key=_focus_key(config, "databricks", period), provider="databricks", period=period,
                signature=_signature(config, databricks, [info.etag for info in usage] + shared), build=build)


def _runs(store: Store, config: Config, record: dict) -> None:
    runs = config.runs
    for month, infos in records_by_month(store, runs.prefixes).items():
        def build(infos=infos):
            rows = []
            for info in infos:
                try:
                    rows.append(flatten_event(json.loads(store.get(info.key)), join_tags=runs.join_tags, source=info.key))
                except ValueError as error:  # json.JSONDecodeError is a ValueError
                    record["warnings"].append(f"runs: {info.key}: {error}")
            return rows, schema.runs_schema()

        key = f"{config.normalized_prefix}/schema=runs-1/event_month={month}/data.parquet"
        _output(store, record, key=key, provider="runs", period=month,
                signature=_signature(config, runs, [f"{info.key}:{info.etag}" for info in infos]), build=build)


_PROVIDERS = (("aws", _aws), ("databricks", _databricks), ("runs", _runs))


def run(store: Store, config: Config, now: datetime) -> dict:
    """Rebuild what changed, write the run record, and raise NormalizeError if a provider failed."""
    record = {"schema": "normalizer-run-1", "started_at": _iso(now), "status": "ok",
              "outputs": [], "warnings": [], "errors": []}
    for name, step in _PROVIDERS:
        if getattr(config, name) is None:
            continue
        try:
            step(store, config, record)
        except Exception as error:  # one provider failing must not stop the others
            record["errors"].append(f"{name}: {type(error).__name__}: {error}")
    record["status"] = "error" if record["errors"] else "ok"
    record["ended_at"] = _iso(datetime.now(UTC))

    body = json.dumps(record, indent=2, sort_keys=True).encode()
    stamp = now.astimezone(UTC).strftime("%Y%m%dT%H%M%SZ")
    for key in (f"{config.normalized_prefix}/_runs/{stamp}.json", f"{config.normalized_prefix}/_runs/latest.json"):
        store.put(key, body, metadata={}, content_type="application/json")
    if record["errors"]:
        raise NormalizeError("; ".join(record["errors"]))
    return record
