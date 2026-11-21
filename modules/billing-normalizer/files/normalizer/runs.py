"""Task-run events (runs-1): one JSON record per event, flattened to one row each.

Records live under a runs prefix at …/date=YYYY-MM-DD/<anything>.json and are
grouped by the month of that date. The node merges a run's started, finished
and swept events by run_key, and joins them to cost rows on the same tags.
"""

import re
from collections.abc import Mapping, Sequence
from datetime import UTC, datetime

from .store import ObjectInfo, Store

RUN_EVENTS = ("started", "finished", "swept")

_DATE = re.compile(r"/date=(\d{4}-\d{2})-\d{2}/")


def records_by_month(store: Store, prefixes: Sequence[str]) -> dict[str, list[ObjectInfo]]:
    """Every *.json record under the prefixes, grouped by the month of its date= folder."""
    months: dict[str, list[ObjectInfo]] = {}
    for prefix in prefixes:
        for info in store.list(f"{prefix}/"):
            match = _DATE.search(info.key)
            if match and info.key.endswith(".json"):
                months.setdefault(match.group(1), []).append(info)
    return {month: sorted(infos, key=lambda i: i.key) for month, infos in sorted(months.items())}


def _timestamp(value, field: str) -> datetime | None:
    if value is None:
        return None
    try:
        parsed = datetime.fromisoformat(str(value))
    except ValueError:
        raise ValueError(f"{field} is not an ISO 8601 time: {value!r}") from None
    return parsed.replace(tzinfo=UTC) if parsed.tzinfo is None else parsed.astimezone(UTC)


def _number(value, kind, field: str):
    if value is None:
        return None
    try:
        return kind(value)
    except (TypeError, ValueError):
        raise ValueError(f"{field} is not a number: {value!r}") from None


def _text(value) -> str | None:
    if value is None:
        return None
    return str(value).strip() or None


def _string_map(value) -> dict[str, str]:
    return {str(k): str(v) for k, v in (value or {}).items() if v is not None}


def flatten_event(record: Mapping, *, join_tags: Sequence[str], source: str) -> dict:
    """One runs-1 row for one event record; ValueError says what is wrong with it."""
    if record.get("schema") != "runs-1":
        raise ValueError(f"schema is {record.get('schema')!r}, not 'runs-1'")
    if record.get("event") not in RUN_EVENTS:
        raise ValueError(f"event is {record.get('event')!r}, not one of {', '.join(RUN_EVENTS)}")
    tags = _string_map(record.get("tags"))
    missing = [tag for tag in join_tags if not tags.get(tag, "").strip()]
    if missing:
        raise ValueError(f"tags lack {', '.join(missing)}")
    project = _text(record.get("project"))
    if project is None:
        raise ValueError("project is blank")
    at = _timestamp(record.get("at"), "at")
    if at is None:
        raise ValueError("at is missing")

    instance = record.get("instance") or {}
    prices = record.get("prices") or {}
    return {
        "run_key": ";".join(f"{tag}={tags[tag]}" for tag in join_tags),
        "tags": tags,
        "event": record["event"],
        "at": at,
        "project": project,
        "campaign": _text(record.get("campaign")),
        "kind": _text(record.get("kind")),
        "instance_type": _text(instance.get("type")),
        "accelerators": _number(instance.get("accelerators"), int, "instance.accelerators"),
        "market": _text(instance.get("market")),
        "zone": _text(instance.get("zone")),
        "instance_id": _text(instance.get("id")),
        "hourly_usd": _number(prices.get("hourly_usd"), float, "prices.hourly_usd"),
        "on_demand_hourly_usd": _number(prices.get("on_demand_hourly_usd"), float, "prices.on_demand_hourly_usd"),
        "worst_case_usd": _number(prices.get("worst_case_usd"), float, "prices.worst_case_usd"),
        "ceiling_usd": _number(prices.get("ceiling_usd"), float, "prices.ceiling_usd"),
        "max_hours": _number(prices.get("max_hours"), float, "prices.max_hours"),
        "outcome": _text(record.get("outcome")),
        "exit_code": _number(record.get("exit_code"), int, "exit_code"),
        "interrupted_at": _timestamp(record.get("interrupted_at"), "interrupted_at"),
        "reason": _text(record.get("reason")),
        "links": _string_map(record.get("links")),
        "attributes": _string_map(record.get("attributes")),
        "x_Source": source,
    }
