"""Test helpers for the normalizer's unit tests. Not shipped in the Lambda."""

import io

import pyarrow as pa
import pyarrow.parquet as pq


def parquet_bytes(rows, schema=None):
    """Rows (a list of dicts) as Parquet bytes, the way a provider delivers them."""
    table = pa.Table.from_pylist(rows, schema=schema)
    sink = io.BytesIO()
    pq.write_table(table, sink)
    return sink.getvalue()
