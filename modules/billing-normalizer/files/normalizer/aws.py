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
from .store import ObjectInfo, Store
from .tags import promote

_PERIOD = re.compile(r"/BILLING_PERIOD=(\d{4}-\d{2})/")


@dataclass(frozen=True)
class AwsDelivery:
    period: str
    execution_id: str
    data_keys: tuple[str, ...]


# Every column map_aws_rows reads: a delivery's other columns are never loaded.
READ_COLUMNS = (*FOCUS_BASE_COLUMNS, "PublisherName")


def latest_aws_manifests(store: Store, delivery_prefix: str) -> dict[str, ObjectInfo]:
    """Each billing period's newest manifest in its metadata folder, by period."""
    newest: dict[str, ObjectInfo] = {}
    for info in store.list(f"{delivery_prefix}/metadata/"):
        match = _PERIOD.search(info.key)
        if not match or not info.key.endswith("Manifest.json"):
            continue
        period = match.group(1)
        if period not in newest or info.last_modified > newest[period].last_modified:
            newest[period] = info
    return dict(sorted(newest.items()))


def read_aws_delivery(store: Store, bucket: str, period: str, manifest: ObjectInfo) -> AwsDelivery:
    """The delivery a manifest names; ValueError if its data files are not in the bucket."""
    body = json.loads(store.get(manifest.key))
    keys = []
    for uri in body.get("dataFiles", []):
        head = f"s3://{bucket}/"
        if not uri.startswith(head):
            raise ValueError(f"{manifest.key}: data file {uri} is not in s3://{bucket}")
        keys.append(uri[len(head):])
    return AwsDelivery(period=period, execution_id=str(body["executionId"]), data_keys=tuple(keys))


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
