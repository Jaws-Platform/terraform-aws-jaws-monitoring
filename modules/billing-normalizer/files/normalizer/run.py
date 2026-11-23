"""One normalizer run: rebuild every output whose sources changed, then record the run.

An output is one (provider, billing period) of the FOCUS table, or one event
month of the runs table. It is rebuilt only when its source signature changes:
the sha256 of MAPPER_VERSION, the provider's configuration, the promoted tags
and the identities of its source objects. The signature is kept on the output
as the S3 user metadata `source-signature`, next to the output's `warnings`,
which every later run reports again for as long as the output stands.

Each output is built on its own: one that fails is reported and every other
output is still built, so a bad old period never freezes the current one. The
runs table goes first, as the smallest and most time-critical. The run record
is always written, to _runs/<time>.json and _runs/latest.json, and the run then
raises if anything failed. Each output is written twice: data.parquet, and its
CSV twin data.csv.gz for the monitoring node (twin.py).
"""

import contextlib
import dataclasses
import hashlib
import json
from collections.abc import Callable
from datetime import UTC, datetime

import pyarrow as pa

from . import schema
from .aws import READ_COLUMNS, latest_aws_manifests, map_aws_rows, read_aws_delivery
from .config import Config
from .databricks import latest_databricks_deliveries, map_databricks_rows
from .parquet import read_rows, write_rows
from .runs import flatten_event, records_by_month
from .store import Store
from .twin import write_twin

PARQUET = "application/vnd.apache.parquet"
GZIP = "application/gzip"

# S3 user metadata is limited to 2 KB in all; warnings beyond this are summarized.
_WARNINGS_BUDGET = 1500


class NormalizeError(RuntimeError):
    """At least one output failed; the run record says which."""


def _iso(moment: datetime) -> str:
    return moment.astimezone(UTC).isoformat().replace("+00:00", "Z")


def _signature(config: Config, provider_config, parts: list[str]) -> str:
    payload = json.dumps(
        [schema.MAPPER_VERSION, dataclasses.asdict(provider_config), list(config.promoted_tags), sorted(parts)],
        sort_keys=True, default=list,
    )
    return hashlib.sha256(payload.encode()).hexdigest()


def _encode_warnings(warnings: list[str]) -> str:
    kept = list(warnings)
    encoded = json.dumps(kept, ensure_ascii=True)
    while len(encoded) > _WARNINGS_BUDGET and kept:
        kept.pop()
        encoded = json.dumps([*kept, f"... and {len(warnings) - len(kept)} more"], ensure_ascii=True)
    return encoded


@contextlib.contextmanager
def _isolated(record: dict, label: str):
    """Record any failure under the label and carry on with the next output."""
    try:
        yield
    except Exception as error:  # one output failing must not stop the others
        record["errors"].append(f"{label}: {type(error).__name__}: {error}")


def _output(
    store: Store,
    record: dict,
    *,
    key: str,
    provider: str,
    period: str,
    signature: str,
    build: Callable[[], tuple[list[dict], pa.Schema, list[str]]],
) -> None:
    current = store.metadata(key)
    if current is not None and current.get("source-signature") == signature:
        warnings = json.loads(current.get("warnings", "[]"))
        record["warnings"].extend(warnings)
        record["outputs"].append({"key": key, "provider": provider, "period": period, "rebuilt": False,
                                  "rows": None, "billed_cost": None, "warnings": warnings})
        return
    rows, table_schema, warnings = build()
    metadata = {"source-signature": signature}
    if warnings:
        metadata["warnings"] = _encode_warnings(warnings)
    # The CSV twin first: the Parquet's signature then only ever marks an output
    # whose twin is written too.
    store.put(_twin_key(key), write_twin(rows, table_schema), metadata=metadata, content_type=GZIP)
    store.put(key, write_rows(rows, table_schema), metadata=metadata, content_type=PARQUET)
    billed = round(sum(row.get("BilledCost") or 0.0 for row in rows), 6) if "BilledCost" in table_schema.names else None
    record["warnings"].extend(warnings)
    record["outputs"].append({"key": key, "provider": provider, "period": period, "rebuilt": True,
                              "rows": len(rows), "billed_cost": billed, "warnings": warnings})


def _twin_key(key: str) -> str:
    """The CSV twin beside a data.parquet output."""
    return key.removesuffix("data.parquet") + "data.csv.gz"


def _focus_key(config: Config, provider: str, period: str) -> str:
    return f"{config.normalized_prefix}/schema=focus-1.2/provider={provider}/billing_period={period}/data.parquet"


def _runs(store: Store, config: Config, record: dict) -> None:
    runs = config.runs
    table_schema = schema.runs_schema()
    for month, infos in records_by_month(store, runs.prefixes).items():
        def build(infos=infos):
            rows, warnings = [], []
            for info in infos:
                # A record is the writer's: whatever is wrong with one, skip it and say so.
                try:
                    row = flatten_event(json.loads(store.get(info.key)), join_tags=runs.join_tags, source=info.key)
                    pa.Table.from_pylist([row], schema=table_schema)  # every value fits its column
                except Exception as error:
                    warnings.append(f"runs: {info.key}: {error}")
                    continue
                rows.append(row)
            return rows, table_schema, warnings

        with _isolated(record, f"runs {month}"):
            key = f"{config.normalized_prefix}/schema=runs-1/event_month={month}/data.parquet"
            _output(store, record, key=key, provider="runs", period=month,
                    signature=_signature(config, runs, [f"{info.key}:{info.etag}" for info in infos]), build=build)


def _aws(store: Store, config: Config, record: dict) -> None:
    aws = config.aws
    manifests = latest_aws_manifests(store, aws.delivery_prefix)
    if not manifests:
        # Deliveries in a layout the normalizer can't read would otherwise
        # leave the AWS dashboards empty with a clean run record.
        listed = sum(1 for _ in store.list(f"{aws.delivery_prefix}/metadata/"))
        if listed:
            record["warnings"].append(
                f"aws: no billing-period manifest matched under {aws.delivery_prefix}/metadata/ "
                f"({listed} object{'' if listed == 1 else 's'} there); check the export's folder layout")
    for period, manifest in manifests.items():
        with _isolated(record, f"aws {period}"):
            delivery = read_aws_delivery(store, config.bucket, period, manifest)

            def build(delivery=delivery):
                rows = []
                for data_key in delivery.data_keys:
                    rows.extend(read_rows(store.get(data_key), columns=READ_COLUMNS))
                mapped = map_aws_rows(rows, promoted_tags=config.promoted_tags,
                                      exclude_publishers=aws.exclude_publishers, source=f"aws:{delivery.execution_id}")
                return mapped, schema.focus_schema(config.promoted_tags), []

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
            warnings = [f"databricks {period}: {unpriced} rows have no list price"] if unpriced else []
            return mapped, schema.focus_schema(config.promoted_tags), warnings

        with _isolated(record, f"databricks {period}"):
            _output(store, record, key=_focus_key(config, "databricks", period), provider="databricks", period=period,
                    signature=_signature(config, databricks, [info.etag for info in usage] + shared), build=build)


_PROVIDERS = (("runs", _runs), ("aws", _aws), ("databricks", _databricks))


def run(store: Store, config: Config, now: datetime) -> dict:
    """Rebuild what changed, write the run record, and raise NormalizeError if anything failed."""
    record = {"schema": "normalizer-run-1", "started_at": _iso(now), "status": "ok",
              "outputs": [], "warnings": [], "errors": []}
    for name, step in _PROVIDERS:
        if getattr(config, name) is None:
            continue
        with _isolated(record, name):  # listing a provider's deliveries failed
            step(store, config, record)
    record["status"] = "error" if record["errors"] else "ok"
    record["ended_at"] = _iso(datetime.now(UTC))

    body = json.dumps(record, indent=2, sort_keys=True).encode()
    stamp = now.astimezone(UTC).strftime("%Y%m%dT%H%M%SZ")
    for key in (f"{config.normalized_prefix}/_runs/{stamp}.json", f"{config.normalized_prefix}/_runs/latest.json"):
        store.put(key, body, metadata={}, content_type="application/json")
    if record["errors"]:
        raise NormalizeError("; ".join(record["errors"]))
    return record
