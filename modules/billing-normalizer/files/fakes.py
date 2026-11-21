"""Test helpers for the normalizer's unit tests. Not shipped in the Lambda."""

import hashlib
import io
from datetime import UTC, datetime, timedelta

import pyarrow as pa
import pyarrow.parquet as pq

from normalizer.store import ObjectInfo


class FakeStore:
    """An in-memory Store. ETags are quoted md5 hex, as S3's for a single-part put."""

    def __init__(self):
        self._objects = {}
        self._clock = datetime(2026, 11, 1, tzinfo=UTC)
        self.puts = []

    def _tick(self):
        self._clock += timedelta(seconds=1)
        return self._clock

    def add(self, key, body, last_modified=None, metadata=None):
        etag = '"' + hashlib.md5(body).hexdigest() + '"'
        info = ObjectInfo(key=key, etag=etag, last_modified=last_modified or self._tick())
        self._objects[key] = (body, info, dict(metadata or {}))

    def list(self, prefix):
        return sorted((info for _, info, _ in self._objects.values() if info.key.startswith(prefix)), key=lambda i: i.key)

    def get(self, key):
        return self._objects[key][0]

    def metadata(self, key):
        entry = self._objects.get(key)
        return None if entry is None else dict(entry[2])

    def put(self, key, body, *, metadata, content_type):
        self.puts.append(key)
        self.add(key, body, metadata=metadata)


def parquet_bytes(rows, schema=None):
    """Rows (a list of dicts) as Parquet bytes, the way a provider delivers them."""
    table = pa.Table.from_pylist(rows, schema=schema)
    sink = io.BytesIO()
    pq.write_table(table, sink)
    return sink.getvalue()
