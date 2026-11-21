"""The normalizer's only boundary: where deliveries are read and outputs written."""

from dataclasses import dataclass
from datetime import datetime
from typing import Protocol


@dataclass(frozen=True)
class ObjectInfo:
    key: str
    etag: str
    last_modified: datetime


class Store(Protocol):
    def list(self, prefix: str) -> list[ObjectInfo]:
        """Every object under the prefix, sorted by key."""

    def get(self, key: str) -> bytes:
        """The object's body."""

    def metadata(self, key: str) -> dict[str, str] | None:
        """The object's user metadata, or None when it does not exist."""

    def put(self, key: str, body: bytes, *, metadata: dict[str, str], content_type: str) -> None:
        """Write the object, replacing any current version."""


class S3Store:
    """A Store over one S3 bucket, through a boto3 S3 client."""

    def __init__(self, bucket: str, client) -> None:
        self.bucket = bucket
        self.client = client

    def list(self, prefix: str) -> list[ObjectInfo]:
        objects = []
        paginator = self.client.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=self.bucket, Prefix=prefix):
            for item in page.get("Contents", []):
                objects.append(ObjectInfo(key=item["Key"], etag=item["ETag"], last_modified=item["LastModified"]))
        return sorted(objects, key=lambda info: info.key)

    def get(self, key: str) -> bytes:
        return self.client.get_object(Bucket=self.bucket, Key=key)["Body"].read()

    def metadata(self, key: str) -> dict[str, str] | None:
        try:
            response = self.client.head_object(Bucket=self.bucket, Key=key)
        except self.client.exceptions.ClientError as error:
            if error.response.get("Error", {}).get("Code") in ("404", "NoSuchKey", "NotFound"):
                return None
            raise
        return dict(response.get("Metadata", {}))

    def put(self, key: str, body: bytes, *, metadata: dict[str, str], content_type: str) -> None:
        self.client.put_object(Bucket=self.bucket, Key=key, Body=body, Metadata=metadata, ContentType=content_type)
