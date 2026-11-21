"""The Lambda entry point: run the normalizer once over the configured bucket.

A failed provider raises after the run record is written, so the invocation
fails and the function's Errors metric shows it.
"""

import os
from datetime import UTC, datetime

from .config import load_config
from .run import run
from .store import S3Store


def handler(event, context):
    import boto3  # only in Lambda: the tests never need it

    config = load_config(os.environ["NORMALIZER_CONFIG"])
    record = run(S3Store(config.bucket, boto3.client("s3")), config, datetime.now(UTC))
    return {"status": record["status"], "rebuilt": sum(1 for output in record["outputs"] if output["rebuilt"])}
