"""The CSV twin of a normalized output (csv-twin-1), for the monitoring node.

The node loads its cost data with Postgres's COPY, and has no Parquet reader.
So each output is also written as gzip CSV that COPY reads exactly:

  - a header row, then the rows, columns in the schema's order;
  - csv.QUOTE_NOTNULL: a NULL is an unquoted empty field, every value is
    quoted (so an empty string stays an empty string);
  - timestamps in ISO 8601 with their offset, booleans true or false, maps as
    JSON objects with sorted keys, floats as Python's repr;
  - gzip with no timestamp, so the same rows give the same bytes.
"""

import csv
import gzip
import io
import json
from collections.abc import Mapping, Sequence
from datetime import date, datetime

import pyarrow as pa


def _cell(value, kind: pa.DataType):
    if value is None:
        return None
    if pa.types.is_map(kind):
        pairs = value.items() if isinstance(value, Mapping) else value
        return json.dumps({str(k): v for k, v in pairs}, sort_keys=True)
    if pa.types.is_boolean(kind):
        return "true" if value else "false"
    if pa.types.is_floating(kind):
        return repr(float(value))
    if pa.types.is_integer(kind):
        return str(int(value))
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    return str(value)


def write_twin(rows: Sequence[Mapping], schema: pa.Schema) -> bytes:
    """The rows as csv-twin-1: gzip bytes, one column per schema field, in order.

    Rows are streamed through gzip, so only the compressed twin is ever held:
    the Lambda already holds the rows and the Parquet.
    """
    out = io.BytesIO()
    with gzip.GzipFile(fileobj=out, mode="wb", mtime=0) as compressed:
        text = io.TextIOWrapper(compressed, encoding="utf-8", newline="")
        writer = csv.writer(text, quoting=csv.QUOTE_NOTNULL, lineterminator="\n")
        writer.writerow(schema.names)
        for row in rows:
            writer.writerow([_cell(row.get(field.name), field.type) for field in schema])
        text.flush()
        text.detach()
    return out.getvalue()
