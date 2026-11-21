"""Parquet in and out, with map columns as plain dicts on the Python side.

Only pyarrow APIs stable across the layer's range (>= 21, < 27) are used.
"""

import io
from collections.abc import Mapping, Sequence

import pyarrow as pa
import pyarrow.parquet as pq


def _is_map(field: pa.Field) -> bool:
    return pa.types.is_map(field.type)


def read_rows(body: bytes) -> list[dict]:
    """Every row of a Parquet object; map columns come back as dicts."""
    table = pq.read_table(io.BytesIO(body))
    maps = [field.name for field in table.schema if _is_map(field)]
    rows = table.to_pylist()
    for row in rows:
        for name in maps:
            if row[name] is not None:
                row[name] = dict(row[name])
    return rows


def write_rows(rows: Sequence[Mapping], schema: pa.Schema) -> bytes:
    """Rows as snappy-compressed Parquet in the given schema; map fields may be dicts."""
    maps = [field.name for field in schema if _is_map(field)]
    prepared = []
    for row in rows:
        row = dict(row)
        for name in maps:
            value = row.get(name)
            if isinstance(value, Mapping):
                row[name] = list(value.items())
        prepared.append(row)
    table = pa.Table.from_pylist(prepared, schema=schema)
    sink = io.BytesIO()
    pq.write_table(table, sink, compression="snappy")
    return sink.getvalue()
