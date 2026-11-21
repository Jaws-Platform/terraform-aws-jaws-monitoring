"""The normalizer's configuration, rendered by Terraform as JSON into NORMALIZER_CONFIG."""

import json
from dataclasses import dataclass


@dataclass(frozen=True)
class AwsConfig:
    delivery_prefix: str
    exclude_publishers: tuple[str, ...]


@dataclass(frozen=True)
class DatabricksConfig:
    prefix: str
    account_name: str
    workspace_names: dict
    workspace_projects: dict


@dataclass(frozen=True)
class RunsConfig:
    prefixes: tuple[str, ...]
    join_tags: tuple[str, ...]


@dataclass(frozen=True)
class Config:
    bucket: str
    normalized_prefix: str
    promoted_tags: tuple[str, ...]
    aws: AwsConfig | None
    databricks: DatabricksConfig | None
    runs: RunsConfig | None


def load_config(raw: str) -> Config:
    """The Config the JSON describes; a null provider is a disabled one."""
    data = json.loads(raw)
    aws, databricks, runs = data.get("aws"), data.get("databricks"), data.get("runs")
    return Config(
        bucket=data["bucket"],
        normalized_prefix=data["normalized_prefix"],
        promoted_tags=tuple(data.get("promoted_tags") or ()),
        aws=None if aws is None else AwsConfig(
            delivery_prefix=aws["delivery_prefix"],
            exclude_publishers=tuple(aws.get("exclude_publishers") or ()),
        ),
        databricks=None if databricks is None else DatabricksConfig(
            prefix=databricks["prefix"],
            account_name=databricks["account_name"],
            workspace_names=dict(databricks.get("workspace_names") or {}),
            workspace_projects=dict(databricks.get("workspace_projects") or {}),
        ),
        runs=None if runs is None else RunsConfig(
            prefixes=tuple(runs["prefixes"]),
            join_tags=tuple(runs["join_tags"]),
        ),
    )
