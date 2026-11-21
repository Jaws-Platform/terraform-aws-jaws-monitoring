"""AWS Data Exports (FOCUS 1.2 with AWS columns): find each billing period's
newest delivery and map its rows to the normalized FOCUS table.

Under the export's delivery prefix AWS writes
  data/BILLING_PERIOD=YYYY-MM/<timestamp>-<execution-id>/<export>-00001.snappy.parquet
  metadata/BILLING_PERIOD=YYYY-MM/…Manifest.json
and a period's newest manifest, written after all of its data files, names
the files of the newest execution.
"""

import json
import re
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass

from .schema import FOCUS_BASE_COLUMNS, promoted_column
from .store import Store
from .tags import promote

_PERIOD = re.compile(r"/BILLING_PERIOD=(\d{4}-\d{2})/")


@dataclass(frozen=True)
class AwsDelivery:
    period: str
    execution_id: str
    data_keys: tuple[str, ...]


def latest_aws_deliveries(store: Store, bucket: str, delivery_prefix: str) -> dict[str, AwsDelivery]:
    """Each billing period's newest delivery, by the newest manifest in its metadata folder."""
    newest = {}
    for info in store.list(f"{delivery_prefix}/metadata/"):
        match = _PERIOD.search(info.key)
        if not match or not info.key.endswith("Manifest.json"):
            continue
        period = match.group(1)
        if period not in newest or info.last_modified > newest[period].last_modified:
            newest[period] = info

    deliveries = {}
    for period, info in sorted(newest.items()):
        body = json.loads(store.get(info.key))
        keys = []
        for uri in body.get("dataFiles", []):
            head = f"s3://{bucket}/"
            if not uri.startswith(head):
                raise ValueError(f"{info.key}: data file {uri} is not in s3://{bucket}")
            keys.append(uri[len(head):])
        deliveries[period] = AwsDelivery(period=period, execution_id=str(body["executionId"]), data_keys=tuple(keys))
    return deliveries


def map_aws_rows(
    rows: Iterable[Mapping],
    *,
    promoted_tags: Sequence[str],
    exclude_publishers: Sequence[str],
    source: str,
) -> list[dict]:
    """FOCUS 1.2 AWS rows as normalized rows; rows from excluded publishers are dropped."""
    excluded = set(exclude_publishers)
    mapped = []
    for row in rows:
        if row.get("PublisherName") in excluded:
            continue
        out = {name: row.get(name) for name in FOCUS_BASE_COLUMNS}
        out["Tags"] = dict(row.get("Tags") or {})
        for tag, value in promote(out["Tags"], promoted_tags).items():
            out[promoted_column(tag)] = value
        out["x_Serverless"] = None
        out["x_Source"] = source
        mapped.append(out)
    return mapped
