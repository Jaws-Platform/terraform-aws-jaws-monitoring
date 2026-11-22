#!/usr/bin/env python3
"""monitoring-cost-sync: load the normalized cost data into Postgres on the node.

Installed by the monitoring-node module; run at boot and every 30 minutes
(monitoring-cost-sync.timer), one run at a time. With no cost-sync/config.json
in the current release, cost is off: it removes its metrics and exits 0.
Otherwise:

  1. make sure the database `cost`, its schema and Grafana's read-only role
     `cost_reader` exist (a schema version change rebuilds the schema: the
     database is a cache of the bucket);
  2. list the normalizer's CSV twins (csv-twin-1) under <prefix>/schema=focus-1.2/
     and <prefix>/schema=runs-1/, never the growing _runs/ history;
  3. load every twin whose ETag changed, each in its own transaction: its old
     rows out, its new rows in, so an output is never doubled or half there,
     and one bad output never stops the rest;
  4. drop the rows of outputs that are gone, and record _runs/latest.json; the
     budgets in the config are rewritten every run, and the cost model (the
     views the dashboards and cost alerts read) is part of the schema;
  5. write node-exporter textfile metrics for the pipeline alerts.

Staleness clocks start at this node's first run when nothing has arrived yet,
so a new node isn't alarmed in its first hours but is once data never comes.
If S3 or Postgres can't be reached, the metrics say only that (success 0 and
when it last worked). Exit status 0 means everything loaded.

Python 3.9 (Amazon Linux 2023's python3), stdlib only; `aws` and `psql` (in the
Postgres container) are called as commands.
"""

from __future__ import annotations

import csv
import fcntl
import gzip
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional

COST_SCHEMA_VERSION = "3"
DEFAULT_PSQL = "docker exec -i monitoring-postgres-1 psql -U monitoring -v ON_ERROR_STOP=1"
DEFAULT_TEXTFILE_DIR = "/var/lib/node_exporter/textfile"
METRICS_FILE = "cost_sync.prom"

SAFE_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
FOCUS_KEY = re.compile(r"/schema=focus-1\.2/provider=([A-Za-z0-9_-]+)/billing_period=(\d{4}-\d{2})/data\.csv\.gz$")
RUNS_KEY = re.compile(r"/schema=runs-1/event_month=(\d{4}-\d{2})/data\.csv\.gz$")
NOT_FOUND = ("404", "Not Found", "NoSuchKey")

TEXT, TIME, NUMBER, INT, BOOL, JSONB = "text", "timestamptz", "double precision", "integer", "boolean", "jsonb"

# (CSV column, table column, type). Unknown CSV columns are ignored; missing ones are NULL.
FOCUS_COLUMNS = [
    ("ProviderName", "provider_name", TEXT), ("BillingAccountId", "billing_account_id", TEXT),
    ("BillingAccountName", "billing_account_name", TEXT), ("SubAccountId", "sub_account_id", TEXT),
    ("SubAccountName", "sub_account_name", TEXT), ("BillingPeriodStart", "billing_period_start", TIME),
    ("ChargePeriodStart", "charge_period_start", TIME), ("ChargePeriodEnd", "charge_period_end", TIME),
    ("ChargeCategory", "charge_category", TEXT), ("ChargeClass", "charge_class", TEXT),
    ("ServiceName", "service_name", TEXT), ("ServiceCategory", "service_category", TEXT),
    ("SkuId", "sku_id", TEXT), ("RegionId", "region_id", TEXT), ("ResourceId", "resource_id", TEXT),
    ("ConsumedQuantity", "consumed_quantity", NUMBER), ("ConsumedUnit", "consumed_unit", TEXT),
    ("ListCost", "list_cost", NUMBER), ("BilledCost", "billed_cost", NUMBER),
    ("EffectiveCost", "effective_cost", NUMBER), ("BillingCurrency", "billing_currency", TEXT),
    ("Tags", "tags", JSONB), ("x_Project", "project", TEXT), ("x_Component", "component", TEXT),
    ("x_Environment", "environment", TEXT), ("x_Serverless", "serverless", BOOL), ("x_Source", "source", TEXT),
]
RUNS_COLUMNS = [
    ("run_key", "run_key", TEXT), ("tags", "tags", JSONB), ("event", "event", TEXT), ("at", "at", TIME),
    ("project", "project", TEXT), ("campaign", "campaign", TEXT), ("kind", "kind", TEXT),
    ("instance_type", "instance_type", TEXT), ("accelerators", "accelerators", INT), ("market", "market", TEXT),
    ("zone", "zone", TEXT), ("instance_id", "instance_id", TEXT), ("hourly_usd", "hourly_usd", NUMBER),
    ("on_demand_hourly_usd", "on_demand_hourly_usd", NUMBER), ("worst_case_usd", "worst_case_usd", NUMBER),
    ("ceiling_usd", "ceiling_usd", NUMBER), ("max_hours", "max_hours", NUMBER), ("outcome", "outcome", TEXT),
    ("exit_code", "exit_code", INT), ("interrupted_at", "interrupted_at", TIME), ("reason", "reason", TEXT),
    ("links", "links", JSONB), ("attributes", "attributes", JSONB), ("x_Source", "source", TEXT),
]

# Stored with each cost row: the UTC day it is dated to (spec 6.6), which every
# view reads by index; and whether it charges for more than a day (a monthly
# fee, a support plan), dated to its period's start. Such a charge is spent, but
# isn't a day's spend: the forecast's average, the anomalies and new untagged
# spend leave it out.
LINES_DERIVED = (
    "day date GENERATED ALWAYS AS ((charge_period_start AT TIME ZONE 'UTC')::date) STORED",
    "long_period boolean GENERATED ALWAYS AS (coalesce(charge_period_end - charge_period_start > interval '1 day', false)) STORED",
)


class Failed(Exception):
    """This run (or one output of it) failed; the message says why."""


def lit(value) -> str:
    """A SQL string literal."""
    return "NULL" if value is None else "'" + str(value).replace("'", "''") + "'"


def read_env(path: Path) -> Dict[str, str]:
    values = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, raw = line.partition("=")
            parts = shlex.split(raw)
            values[key] = parts[0] if parts else ""
    return values


def iso(value: str) -> str:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).isoformat()


def label(value) -> str:
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def write_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def tag_forms(key: str) -> List[str]:
    """The three ways FOCUS may write a user-defined tag's key (AWS doesn't
    document which), in the normalizer's order; cost.tag() reads the same."""
    return [key, "user:" + key, "user_" + key.lower()]


def databricks_sql(workspace_tag: str) -> str:
    """Databricks per day at list price, and each workspace's all-in cost: its
    Databricks list cost plus the AWS rows whose workspace tag names it."""
    keys = "array[" + ", ".join(lit(k) for k in tag_forms(workspace_tag)) + "]"
    return f"""
CREATE OR REPLACE VIEW cost.databricks_daily AS
SELECT day, sub_account_id AS workspace_id, coalesce(sub_account_name, sub_account_id) AS workspace,
       regexp_replace(coalesce(service_name, ''), '^Databricks ', '') AS product, sku_id AS sku,
       coalesce(serverless, false) AS serverless, project, consumed_unit AS unit,
       sum(consumed_quantity) AS quantity, sum(billed_cost) AS list_cost
FROM cost.lines
WHERE provider = 'databricks' AND day <= cost.today()
GROUP BY 1, 2, 3, 4, 5, 6, 7, 8;

-- The AWS side is found through the tags index (?| over the key's three forms):
-- classic clusters' EC2 and EBS, and anything else tagged with the workspace.
CREATE OR REPLACE VIEW cost.databricks_all_in AS
WITH d AS (
  SELECT day, coalesce(sub_account_name, sub_account_id) AS workspace, billed_cost AS dbx, 0::double precision AS aws
  FROM cost.lines WHERE provider = 'databricks' AND day <= cost.today()
  UNION ALL
  SELECT day, cost.tag(tags, {lit(workspace_tag)}), 0, billed_cost
  FROM cost.lines WHERE provider = 'aws' AND tags ?| {keys} AND day <= cost.today()
)
SELECT day, workspace, sum(dbx) AS databricks_cost, sum(aws) AS aws_cost, sum(dbx) + sum(aws) AS all_in_cost
FROM d WHERE workspace IS NOT NULL
GROUP BY day, workspace;
"""


def tasks_sql(join_tags: List[str]) -> str:
    """Task runs: one row per run from its events, its bill (the cost rows
    carrying its join tags, in any of FOCUS's key forms), and the cost model's
    runs and campaigns. Runs with no record are built from tagged cost rows."""
    join = ", ".join(f"{lit(tag)}, s.tags->>{lit(tag)}" for tag in join_tags)
    record_key = " || ';' || ".join(f"{lit(t + '=')} || (s.tags->>{lit(t)})" for t in join_tags)
    first = "array[" + ", ".join(lit(k) for k in tag_forms(join_tags[0])) + "]"
    every = " AND ".join(f"cost.tag(l.tags, {lit(t)}) IS NOT NULL" for t in join_tags)
    key = " || ';' || ".join(f"{lit(t + '=')} || cost.tag(l.tags, {lit(t)})" for t in join_tags)
    return f"""
-- One row per run: its started event, and how it ended.
CREATE OR REPLACE VIEW cost.task_runs AS
WITH s AS (SELECT DISTINCT ON (run_key) * FROM cost.run_events WHERE event = 'started' ORDER BY run_key, at),
     f AS (SELECT DISTINCT ON (run_key) run_key, at, outcome, exit_code, interrupted_at FROM cost.run_events
           WHERE event = 'finished' ORDER BY run_key, at DESC),
     w AS (SELECT DISTINCT ON (run_key) run_key, at, reason FROM cost.run_events WHERE event = 'swept' ORDER BY run_key, at DESC)
SELECT s.run_key, s.tags, jsonb_build_object({join}) AS join_tags, s.project, s.campaign, s.kind,
       s.instance_type, s.accelerators, s.market, s.zone, s.instance_id, s.hourly_usd, s.on_demand_hourly_usd,
       s.worst_case_usd, s.ceiling_usd, s.max_hours, s.links, s.attributes, s.at AS started_at,
       coalesce(f.at, w.at) AS ended_at,
       CASE WHEN f.run_key IS NOT NULL THEN f.outcome WHEN w.run_key IS NOT NULL THEN 'swept' END AS outcome,
       f.exit_code, f.interrupted_at, w.reason AS swept_reason,
       {record_key} AS cost_key
FROM s LEFT JOIN f USING (run_key) LEFT JOIN w USING (run_key);

-- The tagged cost rows, once, by the run their join tags name (in any of the
-- three key forms): one pass through the tags index, however many runs.
CREATE OR REPLACE VIEW cost.run_lines AS
SELECT {key} AS run_key, sum(l.billed_cost) AS billed_cost, count(*) AS lines,
       max(coalesce(l.project, cost.tag(l.tags, 'Project'))) AS project, max(cost.tag(l.tags, 'Campaign')) AS campaign,
       max(cost.tag(l.tags, 'Workflow')) AS workflow, max(cost.tag(l.tags, 'Profile')) AS profile,
       max(cost.tag(l.tags, 'Lifecycle')) AS lifecycle,
       max(cost.tag(l.tags, 'TaskId')) AS task, max(cost.tag(l.tags, 'RunId')) AS run_id,
       min(l.charge_period_start) AS started_at, max(l.charge_period_end) AS ended_at,
       sum(l.consumed_quantity) FILTER (WHERE lower(l.consumed_unit) IN ('hrs', 'hours', 'hour')) AS hours
FROM cost.lines l
WHERE l.tags ?| {first} AND {every}
GROUP BY 1;

-- A run's billed cost: its tagged cost rows.
CREATE OR REPLACE VIEW cost.task_run_costs AS
SELECT r.run_key, coalesce(x.billed_cost, 0) AS billed_cost, coalesce(x.lines, 0) AS lines
FROM cost.task_runs r LEFT JOIN cost.run_lines x ON x.run_key = r.cost_key;

-- One row per run: recorded runs, and runs known only from tagged cost rows
-- (before records existed, or when one failed to write). Until a run's last day
-- is complete, its cost is an estimate: its hours at the hourly price paid.
CREATE OR REPLACE VIEW cost.runs AS
WITH rl AS (SELECT * FROM cost.run_lines), recorded AS (
  SELECT r.run_key, 'record'::text AS source, r.project, r.campaign, r.kind AS workflow,
         r.attributes->>'profile' AS profile, r.attributes->>'lifecycle' AS lifecycle,
         cost.tag(r.tags, 'TaskId') AS task, cost.tag(r.tags, 'RunId') AS run_id,
         r.instance_type, r.accelerators, r.market, r.zone, r.instance_id,
         r.started_at, r.ended_at, r.ended_at IS NULL AS running,
         (extract(epoch FROM coalesce(r.ended_at, cost.now()) - r.started_at) / 3600)::double precision AS hours,
         coalesce(r.outcome, CASE WHEN r.ended_at IS NULL THEN 'running' END) AS outcome,
         coalesce(x.billed_cost, 0) AS billed_cost, coalesce(x.lines, 0) AS lines,
         r.hourly_usd, r.on_demand_hourly_usd, r.ceiling_usd, r.max_hours,
         r.links->>'run' AS run_url, r.links->>'pr' AS pr_url, r.links->>'commit' AS commit_url
  FROM cost.task_runs r LEFT JOIN rl x ON x.run_key = r.cost_key
), tagged AS (
  SELECT x.run_key, 'tags'::text AS source, x.project, x.campaign, x.workflow, x.profile, x.lifecycle, x.task, x.run_id,
         NULL::text AS instance_type, NULL::integer AS accelerators, NULL::text AS market, NULL::text AS zone,
         NULL::text AS instance_id, x.started_at, x.ended_at, false AS running, x.hours,
         NULL::text AS outcome, x.billed_cost, x.lines,
         NULL::double precision AS hourly_usd, NULL::double precision AS on_demand_hourly_usd,
         NULL::double precision AS ceiling_usd, NULL::double precision AS max_hours,
         NULL::text AS run_url, NULL::text AS pr_url, NULL::text AS commit_url
  FROM rl x
  WHERE NOT EXISTS (SELECT 1 FROM cost.task_runs t WHERE t.cost_key = x.run_key)
), e AS (
  SELECT x.*, (x.hourly_usd IS NOT NULL AND (x.running OR x.lines = 0
               OR (x.ended_at AT TIME ZONE 'UTC')::date > cost.last_complete())) AS estimated
  FROM (SELECT * FROM recorded UNION ALL SELECT * FROM tagged) x
), c AS (
  SELECT e.*, CASE WHEN e.estimated THEN e.hours * e.hourly_usd ELSE e.billed_cost END AS cost FROM e
)
SELECT run_key, source, project, campaign, workflow, profile, lifecycle, task, run_id,
       instance_type, accelerators, market, zone, instance_id, started_at, ended_at, running, hours, outcome,
       billed_cost, estimated, cost, hourly_usd, on_demand_hourly_usd, ceiling_usd, max_hours,
       hours * on_demand_hourly_usd AS on_demand_cost,
       100 * cost / nullif(ceiling_usd, 0) AS ceiling_percent,
       hours * accelerators AS gpu_hours,
       cost / nullif(hours * accelerators, 0) AS cost_per_gpu_hour,
       run_url, pr_url, commit_url,
       '#' || substring(pr_url FROM '[^/]+$') AS pr,
       left(substring(commit_url FROM '[^/]+$'), 7) AS commit
FROM c;

-- Campaigns: a set of runs toward one goal, by their campaign slug.
CREATE OR REPLACE VIEW cost.campaigns AS
SELECT campaign, project, min(started_at) AS first_run, max(started_at) AS last_run, count(*) AS runs,
       count(*) FILTER (WHERE outcome = 'passed') AS passed,
       count(*) FILTER (WHERE outcome = 'failed') AS failed,
       count(*) FILTER (WHERE outcome = 'interrupted') AS interrupted,
       sum(hours) AS instance_hours, sum(gpu_hours) AS gpu_hours, sum(cost) AS cost,
       sum(on_demand_cost) AS on_demand_cost,
       sum(on_demand_cost - cost) FILTER (WHERE on_demand_cost IS NOT NULL) AS saved,
       100 * sum(on_demand_cost - cost) FILTER (WHERE on_demand_cost IS NOT NULL) / nullif(sum(on_demand_cost), 0) AS saved_percent,
       sum(cost) / nullif(count(*) FILTER (WHERE outcome = 'passed'), 0) AS cost_per_passed_run
FROM cost.runs
WHERE campaign IS NOT NULL
GROUP BY campaign, project;
"""


def schema_sql(join_tags: List[str], workspace_tag: str = "Workspace") -> str:
    def table(name: str, leading: List[str], columns, trailing: tuple = ()) -> str:
        return (f"CREATE TABLE IF NOT EXISTS cost.{name} "
                f"({', '.join(leading + [f'{c} {t}' for _, c, t in columns] + list(trailing))});\n")

    return (
        "CREATE TABLE IF NOT EXISTS cost.loads (key text PRIMARY KEY, kind text NOT NULL, provider text, "
        "period text NOT NULL, etag text NOT NULL, last_modified timestamptz NOT NULL, rows integer NOT NULL, "
        "billed_cost double precision, loaded_at timestamptz NOT NULL);\n"
        + table("lines", ["key text NOT NULL", "provider text NOT NULL", "period text NOT NULL"], FOCUS_COLUMNS,
                LINES_DERIVED)
        + "CREATE INDEX IF NOT EXISTS lines_key ON cost.lines (key);\n"
        "CREATE INDEX IF NOT EXISTS lines_day ON cost.lines (day);\n"
        "CREATE INDEX IF NOT EXISTS lines_provider_charge ON cost.lines (provider, charge_period_start);\n"
        "CREATE INDEX IF NOT EXISTS lines_tags ON cost.lines USING gin (tags);\n"
        + table("run_events", ["key text NOT NULL", "period text NOT NULL"], RUNS_COLUMNS)
        + "CREATE INDEX IF NOT EXISTS run_events_key ON cost.run_events (key);\n"
        "CREATE INDEX IF NOT EXISTS run_events_run ON cost.run_events (run_key);\n"
        "CREATE TABLE IF NOT EXISTS cost.normalizer_runs (started_at timestamptz PRIMARY KEY, ended_at timestamptz, "
        "status text NOT NULL, errors integer NOT NULL, warnings integer NOT NULL, record jsonb NOT NULL);\n"
        + MODEL_SQL
        + tasks_sql(join_tags)
        + databricks_sql(workspace_tag)
        + "GRANT CONNECT ON DATABASE cost TO cost_reader;\n"
        "GRANT USAGE ON SCHEMA cost TO cost_reader;\n"
        "GRANT SELECT ON ALL TABLES IN SCHEMA cost TO cost_reader;\n"
        f"INSERT INTO cost.meta VALUES ('schema_version', {lit(COST_SCHEMA_VERSION)}) "
        "ON CONFLICT (name) DO UPDATE SET value = EXCLUDED.value;\n"
    )


# __NOW__ is now(), or MONITORING_NOW (Unix seconds) for tests. Only runs from
# the last 7 days can be over their ceiling: the bill arrives a day or two after
# a run and never shrinks, so an older one would be reported forever.
# The cost model: what the dashboards and the cost alerts read. Days are UTC
# days of charge_period_start; a day is complete once its end is 48 hours old
# (spec 6.6). cost.now() is now() unless a session sets cost.now (the tests).
MODEL_SQL = """
CREATE OR REPLACE FUNCTION cost.now() RETURNS timestamptz LANGUAGE sql STABLE AS
$$ SELECT coalesce(nullif(current_setting('cost.now', true), '')::timestamptz, now()) $$;
-- A tag's value, whichever of FOCUS's three key forms it was written in.
CREATE OR REPLACE FUNCTION cost.tag(tags jsonb, key text) RETURNS text LANGUAGE sql IMMUTABLE AS
$$ SELECT coalesce(tags->>key, tags->>('user:' || key), tags->>('user_' || lower(key))) $$;
-- Stable, so a view's window on day is pushed down to the lines_day index.
CREATE OR REPLACE FUNCTION cost.today() RETURNS date LANGUAGE sql STABLE AS
$$ SELECT (cost.now() AT TIME ZONE 'UTC')::date $$;
CREATE OR REPLACE FUNCTION cost.last_complete() RETURNS date LANGUAGE sql STABLE AS
$$ SELECT ((cost.now() AT TIME ZONE 'UTC') - interval '72 hours')::date $$;
CREATE OR REPLACE FUNCTION cost.month_start() RETURNS date LANGUAGE sql STABLE AS
$$ SELECT date_trunc('month', cost.now() AT TIME ZONE 'UTC')::date $$;
CREATE OR REPLACE FUNCTION cost.next_month() RETURNS date LANGUAGE sql STABLE AS
$$ SELECT (date_trunc('month', cost.now() AT TIME ZONE 'UTC') + interval '1 month')::date $$;

CREATE TABLE IF NOT EXISTS cost.budgets (scope text NOT NULL, name text NOT NULL,
  monthly_usd double precision NOT NULL, PRIMARY KEY (scope, name));

-- Spend per UTC day, up to today (a pinned cost.now sees no later rows).
CREATE OR REPLACE VIEW cost.daily AS
SELECT day, day <= cost.last_complete() AS complete, long_period,
       provider, sub_account_id AS account_id, sub_account_name AS account_name,
       coalesce(project, '(untagged)') AS project, environment, component, service_name AS service, charge_category,
       sum(billed_cost) AS billed_cost
FROM cost.lines
WHERE day <= cost.today()
GROUP BY day, long_period, provider, sub_account_id, sub_account_name, coalesce(project, '(untagged)'),
         environment, component, service_name, charge_category;

CREATE OR REPLACE VIEW cost.as_of AS
SELECT max(day) AS day FROM cost.lines WHERE day <= cost.last_complete();

-- One row per budget scope: the total, each project, each account (by id; a
-- budget may name the account by id or name). The forecast is the month's
-- long-period charges and complete days, plus, for each day of the month not
-- complete yet, what it has so far or the last 7 complete days' average,
-- whichever is more. It is never below the month's spend.
CREATE OR REPLACE VIEW cost.month_to_date AS
WITH recent AS (
  SELECT * FROM cost.daily WHERE day >= least(cost.month_start(), cost.last_complete() - 6)
), scoped AS (
  SELECT 'total'::text AS scope, 'total'::text AS name, NULL::text AS alt, day, long_period, billed_cost FROM recent
  UNION ALL SELECT 'project', project, NULL, day, long_period, billed_cost FROM recent
  UNION ALL SELECT 'account', account_id, account_name, day, long_period, billed_cost FROM recent WHERE account_id IS NOT NULL
), spent AS (
  SELECT scope, name, max(alt) AS alt FROM scoped WHERE day >= cost.month_start() GROUP BY scope, name
), names AS (
  SELECT scope, name, alt FROM spent
  UNION ALL
  SELECT b.scope, b.name, NULL FROM cost.budgets b
  WHERE NOT EXISTS (SELECT 1 FROM spent x WHERE x.scope = b.scope AND (x.name = b.name OR x.alt = b.name))
), sums AS (
  SELECT n.scope, n.name, n.alt,
    coalesce(sum(s.billed_cost) FILTER (WHERE s.day >= cost.month_start()), 0) AS mtd,
    coalesce(sum(s.billed_cost) FILTER (WHERE s.day >= cost.month_start() AND s.long_period), 0) AS long_mtd,
    coalesce(sum(s.billed_cost) FILTER (WHERE s.day >= cost.month_start() AND s.day <= cost.last_complete()
                                          AND NOT s.long_period), 0) AS complete_mtd,
    coalesce(sum(s.billed_cost) FILTER (WHERE s.day > cost.last_complete() - 7 AND s.day <= cost.last_complete()
                                          AND NOT s.long_period), 0) / 7.0 AS avg7
  FROM names n LEFT JOIN scoped s ON s.scope = n.scope AND s.name = n.name
  GROUP BY n.scope, n.name, n.alt
), per_day AS (
  SELECT scope, name, day, sum(billed_cost) AS spend FROM scoped
  WHERE NOT long_period AND day > cost.last_complete() GROUP BY scope, name, day
), ahead AS (
  SELECT x.scope, x.name, sum(greatest(coalesce(p.spend, 0), x.avg7)) AS rest
  FROM sums x
  CROSS JOIN generate_series(0, cost.next_month() - greatest(cost.last_complete() + 1, cost.month_start()) - 1) AS i
  LEFT JOIN per_day p ON p.scope = x.scope AND p.name = x.name
                     AND p.day = greatest(cost.last_complete() + 1, cost.month_start()) + i
  GROUP BY x.scope, x.name
), f AS (
  SELECT x.scope, x.name, x.alt, x.mtd, x.complete_mtd, x.avg7,
         cost.next_month() - greatest(cost.last_complete() + 1, cost.month_start()) AS days_left,
         x.long_mtd + x.complete_mtd + coalesce(a.rest, 0) AS forecast
  FROM sums x LEFT JOIN ahead a ON a.scope = x.scope AND a.name = x.name
)
SELECT f.scope, f.name, f.mtd, f.complete_mtd, f.avg7, f.days_left, f.forecast,
       b.monthly_usd AS budget,
       100 * f.mtd / b.monthly_usd AS used_percent,
       100 * f.forecast / b.monthly_usd AS forecast_percent
FROM f
LEFT JOIN LATERAL (SELECT monthly_usd FROM cost.budgets bb
                   WHERE bb.scope = f.scope AND (bb.name = f.name OR bb.name = f.alt)
                   ORDER BY bb.name = f.name DESC LIMIT 1) b ON true;

-- Each of the last three days with data (a provider that reports a day late
-- is judged when its day lands): its spend against the median of the 14
-- complete days before it (a complete day with no rows counts 0).
CREATE OR REPLACE VIEW cost.anomalies AS
WITH t AS (
  SELECT max(day) AS newest FROM cost.lines WHERE day <= cost.today() AND NOT long_period
), recent AS (
  SELECT day, project, service, billed_cost FROM cost.daily WHERE day >= cost.today() - 45 AND NOT long_period
), scoped AS (
  SELECT 'total'::text AS kind, 'total'::text AS name, day, billed_cost FROM recent
  UNION ALL SELECT 'project', project, day, billed_cost FROM recent
  UNION ALL SELECT 'service', service, day, billed_cost FROM recent
), per_day AS (
  SELECT kind, name, day, sum(billed_cost) AS spend FROM scoped GROUP BY kind, name, day
), judged AS (
  SELECT p.kind, p.name, p.day, p.spend, least(p.day - 1, cost.last_complete()) AS base_end
  FROM per_day p, t WHERE p.day >= t.newest - 2
), med AS (
  SELECT j.kind, j.name, j.day, percentile_cont(0.5) WITHIN GROUP (ORDER BY coalesce(p.spend, 0)) AS median14
  FROM judged j CROSS JOIN generate_series(0, 13) AS i
  LEFT JOIN per_day p ON p.kind = j.kind AND p.name = j.name AND p.day = j.base_end - i
  GROUP BY j.kind, j.name, j.day
)
SELECT j.kind, j.name, j.day, j.spend, m.median14,
       CASE WHEN m.median14 > 0 THEN j.spend / m.median14 END AS ratio,
       j.spend - m.median14 AS excess
FROM judged j JOIN med m ON m.kind = j.kind AND m.name = j.name AND m.day = j.day;

-- Untagged spend: no project, and not tax or credit, which no tag can carry.
CREATE OR REPLACE VIEW cost.untagged AS
SELECT day, long_period, account_id, max(account_name) AS account_name, service, sum(billed_cost) AS billed_cost
FROM cost.daily
WHERE project = '(untagged)' AND coalesce(charge_category, '') NOT IN ('Tax', 'Credit')
GROUP BY day, long_period, account_id, service;

-- Each account and service with untagged spend in the 16 days to the newest:
-- its first day there and its spend since. It is new when that first day is the
-- newest or the day before (none in the 14 days before), so a charge that
-- starts late in a day is still new the next day, when it has a whole day's
-- spend, and a steady charge is new only once.
CREATE OR REPLACE VIEW cost.untagged_new AS
WITH t AS (SELECT max(day) AS newest FROM cost.lines WHERE day <= cost.today() AND NOT long_period)
SELECT u.account_id, max(u.account_name) AS account_name, u.service, min(u.day) AS first_day,
       sum(u.billed_cost) AS spend, min(u.day) >= t.newest - 1 AS is_new
FROM cost.untagged u CROSS JOIN t
WHERE u.day >= cost.today() - 45 AND u.day >= t.newest - 15 AND NOT u.long_period
GROUP BY u.account_id, u.service, t.newest;
"""


MEASURE_SQL = """SELECT json_build_object(
  'outputs', (SELECT count(*) FROM cost.loads),
  'newest_charge', (SELECT coalesce(json_object_agg(provider, t), '{}') FROM
      (SELECT provider, extract(epoch FROM max(charge_period_start)) AS t FROM cost.lines GROUP BY provider) x),
  'newest_output', (SELECT coalesce(json_object_agg(provider, t), '{}') FROM
      (SELECT provider, extract(epoch FROM max(last_modified)) AS t FROM cost.loads WHERE kind = 'focus' GROUP BY provider) x),
  'normalizer_last_success', (SELECT extract(epoch FROM max(ended_at)) FROM cost.normalizer_runs WHERE status = 'ok'),
  'normalizer_latest', (SELECT json_build_object('status', status, 'errors', errors, 'warnings', warnings)
      FROM cost.normalizer_runs ORDER BY started_at DESC LIMIT 1),
  'overdue', (SELECT coalesce(json_agg(json_build_object('project', project, 'run_key', run_key,
        'instance_id', coalesce(instance_id, ''), 'hours', extract(epoch FROM __NOW__ - started_at) / 3600 - (max_hours + 1))
        ORDER BY run_key), '[]')
      FROM cost.task_runs WHERE ended_at IS NULL AND max_hours IS NOT NULL
        AND __NOW__ > started_at + make_interval(secs => (max_hours + 1) * 3600)),
  'over_ceiling', (SELECT coalesce(json_agg(json_build_object('project', r.project, 'run_key', r.run_key,
        'usd', c.billed_cost - r.ceiling_usd) ORDER BY r.run_key), '[]')
      FROM cost.task_runs r JOIN cost.task_run_costs c USING (run_key)
      WHERE r.ceiling_usd IS NOT NULL AND c.billed_cost > r.ceiling_usd
        AND r.started_at > __NOW__ - interval '7 days')
);
"""


class CostSync:
    def __init__(self, root: Path) -> None:
        self.root = root
        node_env = root / "etc/monitoring/node.env"
        self.region = read_env(node_env).get("REGION") if node_env.exists() else None
        self.config_file = root / "data/config/current/cost-sync/config.json"
        self.state_file = root / "data/cost-sync/state.json"
        self.secret_file = root / "data/secrets/COST_READER_PASSWORD"
        self.textfile = Path(os.environ.get("MONITORING_TEXTFILE_DIR", DEFAULT_TEXTFILE_DIR)) / METRICS_FILE
        self.psql_prefix = shlex.split(os.environ.get("MONITORING_PSQL", DEFAULT_PSQL))
        self.errors: List[str] = []

    # ------------------------------------------------------------ commands
    def aws(self, *args: str) -> str:
        region = ["--region", self.region] if self.region else []
        result = subprocess.run(["aws", *region, *args], capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or f"aws {' '.join(args[:2])} failed")
        return result.stdout

    def psql(self, database: str, sql: str, query: bool = False) -> str:
        command = [*self.psql_prefix, "-d", database, "-X", "-q", *(["-At"] if query else [])]
        result = subprocess.run(command, input=sql, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or "psql failed")
        return result.stdout

    # --------------------------------------------------------------- state
    def load_state(self) -> dict:
        try:
            return json.loads(self.state_file.read_text())
        except (OSError, ValueError):
            return {}

    def save_state(self, state: dict) -> None:
        write_atomic(self.state_file, json.dumps(state))

    # --------------------------------------------------------------- steps
    def setup(self, config: dict) -> None:
        password = self.secret_file.read_text().strip() if self.secret_file.exists() else ""
        if not password:
            raise Failed("missing secret COST_READER_PASSWORD")
        # Roles are the cluster's, the database is created outside a transaction;
        # the password travels in the stream, never in argv.
        self.psql("postgres",
                  "SELECT 'CREATE DATABASE cost' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'cost')\\gexec\n"
                  "SELECT 'CREATE ROLE cost_reader LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'cost_reader')\\gexec\n"
                  f"ALTER ROLE cost_reader WITH LOGIN PASSWORD {lit(password)};\n")
        version = self.psql("cost",
                            "CREATE SCHEMA IF NOT EXISTS cost;\n"
                            "CREATE TABLE IF NOT EXISTS cost.meta (name text PRIMARY KEY, value text NOT NULL);\n"
                            "SELECT value FROM cost.meta WHERE name = 'schema_version';\n", query=True).strip()
        rebuild = ""
        if version and version != COST_SCHEMA_VERSION:
            print(f"monitoring-cost-sync: schema {version} -> {COST_SCHEMA_VERSION}, rebuilding", file=sys.stderr)
            rebuild = ("DROP SCHEMA cost CASCADE;\nCREATE SCHEMA cost;\n"
                       "CREATE TABLE cost.meta (name text PRIMARY KEY, value text NOT NULL);\n")
        self.psql("cost", "BEGIN;\n" + rebuild + schema_sql(config["run_join_tags"], config.get("databricks_workspace_tag") or "Workspace")
                  + "COMMIT;\n")

    def write_budgets(self, config: dict) -> None:
        """Rewrite cost.budgets from the bundle: what isn't there any more goes."""
        budgets = config.get("budgets") or {}
        rows = [("total", "total", budgets["total"])] if budgets.get("total") is not None else []
        rows += [("project", name, usd) for name, usd in sorted((budgets.get("projects") or {}).items())]
        rows += [("account", name, usd) for name, usd in sorted((budgets.get("accounts") or {}).items())]
        values = ", ".join(f"({lit(scope)}, {lit(name)}, {float(usd)!r})" for scope, name, usd in rows)
        self.psql("cost", "BEGIN;\nDELETE FROM cost.budgets;\n"
                  + (f"INSERT INTO cost.budgets (scope, name, monthly_usd) VALUES {values};\n" if rows else "")
                  + "COMMIT;\n")

    def list_outputs(self, config: dict) -> Dict[str, dict]:
        outputs = {}
        for schema in ("schema=focus-1.2/", "schema=runs-1/"):
            text = self.aws("s3api", "list-objects-v2", "--bucket", config["bucket"],
                            "--prefix", f"{config['prefix']}/{schema}", "--output", "json")
            for item in (json.loads(text) if text.strip() else {}).get("Contents") or []:
                key = item["Key"]
                info = {"etag": item["ETag"], "last_modified": iso(item["LastModified"])}
                focus, runs = FOCUS_KEY.search(key), RUNS_KEY.search(key)
                if focus:
                    outputs[key] = {**info, "kind": "focus", "provider": focus.group(1), "period": focus.group(2)}
                elif runs:
                    outputs[key] = {**info, "kind": "runs", "provider": None, "period": runs.group(1)}
        return outputs

    def loaded(self) -> Dict[str, str]:
        text = self.psql("cost", "SELECT key || ' ' || etag FROM cost.loads;\n", query=True)
        return dict(line.split(" ", 1) for line in text.splitlines() if line)

    def load(self, key: str, info: dict, config: dict) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "data.csv.gz"
            self.aws("s3", "cp", f"s3://{config['bucket']}/{key}", str(path), "--only-show-errors")
            try:
                with gzip.open(path, "rt", encoding="utf-8", newline="") as handle:
                    data = handle.read()
            except (OSError, EOFError, UnicodeDecodeError) as error:
                raise Failed(f"not a gzip CSV: {error}") from None
        header = next(csv.reader([data.partition("\n")[0]]), [])
        unsafe = [name for name in header if not SAFE_NAME.match(name)]
        if not header or unsafe:
            raise Failed(f"unusable column names {unsafe or header}")

        focus = info["kind"] == "focus"
        table, columns = ("lines", FOCUS_COLUMNS) if focus else ("run_events", RUNS_COLUMNS)
        present = set(header)
        targets = ["key", *(["provider"] if focus else []), "period"]
        values = [lit(key), *([lit(info["provider"])] if focus else []), lit(info["period"])]
        for csv_name, column, kind in columns:
            targets.append(column)
            values.append(f'"{csv_name}"::{kind}' if csv_name in present else f"NULL::{kind}")
        billed = 'sum("BilledCost"::double precision)' if focus and "BilledCost" in present else "NULL"
        if not data.endswith("\n"):
            data += "\n"
        stage = ", ".join(f'"{name}" text' for name in header)
        self.psql("cost", (
            "BEGIN;\n"
            f"CREATE TEMP TABLE stage ({stage}) ON COMMIT DROP;\n"
            "COPY stage FROM STDIN WITH (FORMAT csv, HEADER true);\n"
            f"{data}\\.\n"
            f"DELETE FROM cost.{table} WHERE key = {lit(key)};\n"
            f"INSERT INTO cost.{table} ({', '.join(targets)}) SELECT {', '.join(values)} FROM stage;\n"
            "INSERT INTO cost.loads (key, kind, provider, period, etag, last_modified, rows, billed_cost, loaded_at)\n"
            f"SELECT {lit(key)}, {lit(info['kind'])}, {lit(info['provider'])}, {lit(info['period'])}, {lit(info['etag'])},\n"
            f"       {lit(info['last_modified'])}, count(*), {billed}, now() FROM stage\n"
            "ON CONFLICT (key) DO UPDATE SET kind = EXCLUDED.kind, provider = EXCLUDED.provider, period = EXCLUDED.period,\n"
            "  etag = EXCLUDED.etag, last_modified = EXCLUDED.last_modified, rows = EXCLUDED.rows,\n"
            "  billed_cost = EXCLUDED.billed_cost, loaded_at = EXCLUDED.loaded_at;\n"
            "COMMIT;\n"))

    def remove(self, keys: List[str]) -> None:
        if not keys:
            return
        listed = ", ".join(lit(key) for key in keys)
        self.psql("cost", (
            "BEGIN;\n"
            f"DELETE FROM cost.lines WHERE key IN ({listed});\n"
            f"DELETE FROM cost.run_events WHERE key IN ({listed});\n"
            f"DELETE FROM cost.loads WHERE key IN ({listed});\n"
            "COMMIT;\n"))

    def record_normalizer(self, config: dict) -> None:
        # List it first: the role may list only under the prefix, so S3 answers
        # a GET of a missing key with 403, not 404.
        key = f"{config['prefix']}/_runs/latest.json"
        listing = self.aws("s3api", "list-objects-v2", "--bucket", config["bucket"], "--prefix", key, "--output", "json")
        if not any(item.get("Key") == key for item in (json.loads(listing) if listing.strip() else {}).get("Contents") or []):
            return  # the normalizer hasn't run yet
        try:
            text = self.aws("s3", "cp", f"s3://{config['bucket']}/{config['prefix']}/_runs/latest.json", "-", "--only-show-errors")
        except RuntimeError as error:
            if any(marker in str(error) for marker in NOT_FOUND):
                return  # the normalizer hasn't run yet
            raise
        record = json.loads(text)
        self.psql("cost", (
            "INSERT INTO cost.normalizer_runs (started_at, ended_at, status, errors, warnings, record) VALUES ("
            f"{lit(record['started_at'])}, {lit(record.get('ended_at'))}, {lit(record.get('status', 'unknown'))}, "
            f"{len(record.get('errors') or [])}, {len(record.get('warnings') or [])}, {lit(json.dumps(record))}::jsonb)\n"
            "ON CONFLICT (started_at) DO UPDATE SET ended_at = EXCLUDED.ended_at, status = EXCLUDED.status,\n"
            "  errors = EXCLUDED.errors, warnings = EXCLUDED.warnings, record = EXCLUDED.record;\n"))

    def measure(self) -> dict:
        at = os.environ.get("MONITORING_NOW")
        now = f"to_timestamp({int(at)})" if at else "now()"
        return json.loads(self.psql("cost", MEASURE_SQL.replace("__NOW__", now), query=True))

    # ------------------------------------------------------------- metrics
    def write_metrics(self, state: dict, config: dict, values: Optional[dict], ok: bool) -> None:
        first = state["first_run"]
        lines: List[str] = []

        def gauge(name: str, help_text: str, series: list) -> None:
            lines.append(f"# HELP {name} {help_text}")
            lines.append(f"# TYPE {name} gauge")
            for labels, value in series:
                rendered = ",".join(f'{k}="{label(v)}"' for k, v in labels)
                lines.append(f"{name}{{{rendered}}} {value}" if rendered else f"{name} {value}")

        gauge("monitoring_cost_sync_success", "1 if the last cost-sync run loaded everything.", [((), 1 if ok else 0)])
        gauge("monitoring_cost_sync_last_success_seconds", "When cost-sync last succeeded (its first run until then).",
              [((), int(state.get("last_success", first)))])
        if values is not None:
            latest = values.get("normalizer_latest") or {}
            providers = sorted(config["providers"])
            gauge("monitoring_cost_sync_outputs", "Normalized outputs loaded.", [((), values["outputs"])])
            gauge("monitoring_normalizer_last_success_seconds", "When the newest successful normalizer run seen ended.",
                  [((), int(values["normalizer_last_success"] or first))])
            gauge("monitoring_normalizer_last_run_failed", "1 if the newest normalizer run failed.",
                  [((), 1 if latest.get("status") == "error" else 0)])
            gauge("monitoring_normalizer_errors", "Errors in the newest normalizer run.", [((), latest.get("errors", 0))])
            gauge("monitoring_normalizer_warnings", "Warnings in the newest normalizer run.", [((), latest.get("warnings", 0))])
            gauge("monitoring_cost_newest_charge_seconds", "The newest charge date loaded, per provider.",
                  [((("provider", p),), int(values["newest_charge"].get(p) or first)) for p in providers])
            gauge("monitoring_cost_newest_output_seconds", "When each provider's newest normalized output was written.",
                  [((("provider", p),), int(values["newest_output"].get(p) or first)) for p in providers])
            gauge("monitoring_task_run_overdue_hours", "Hours a run without an end is past its max hours plus one.",
                  [((("project", r["project"]), ("run_key", r["run_key"]), ("instance_id", r["instance_id"])),
                    round(r["hours"], 3)) for r in values["overdue"]])
            gauge("monitoring_task_run_over_ceiling_usd", "How far a run's billed cost is over its ceiling.",
                  [((("project", r["project"]), ("run_key", r["run_key"])), round(r["usd"], 4)) for r in values["over_ceiling"]])
        write_atomic(self.textfile, "\n".join(lines) + "\n")

    # ----------------------------------------------------------------- run
    def run(self) -> int:
        if not self.config_file.exists():
            if self.textfile.exists():
                self.textfile.unlink()
            return 0
        config = json.loads(self.config_file.read_text())
        state = self.load_state()
        started = int(time.time())
        if "first_run" not in state:
            state["first_run"] = started
            self.save_state(state)

        try:
            self.setup(config)
            listed = self.list_outputs(config)
            loaded = self.loaded()
            # Only once S3 answered: a run that can't reach it changes nothing.
            self.write_budgets(config)
        except (RuntimeError, Failed, ValueError, KeyError) as error:
            print(f"monitoring-cost-sync: failed: {error}", file=sys.stderr)
            self.write_metrics(state, config, None, ok=False)
            return 1

        for key, info in sorted(listed.items()):
            if loaded.get(key) == info["etag"]:
                continue
            try:
                self.load(key, info, config)
            except (RuntimeError, Failed) as error:  # this output only: the rest still load
                self.errors.append(f"{key}: {error}")

        try:
            self.remove(sorted(set(loaded) - set(listed)))
            self.record_normalizer(config)
            values = self.measure()
        except (RuntimeError, Failed, ValueError, KeyError) as error:
            print(f"monitoring-cost-sync: failed: {error}", file=sys.stderr)
            self.write_metrics(state, config, None, ok=False)
            return 1

        for error in self.errors:
            print(f"monitoring-cost-sync: {error}", file=sys.stderr)
        ok = not self.errors
        if ok:
            state["last_success"] = started
            self.save_state(state)
        self.write_metrics(state, config, values, ok)
        return 0 if ok else 1


def main() -> int:
    root = Path(os.environ.get("MONITORING_ROOT", "/"))
    (root / "run").mkdir(parents=True, exist_ok=True)
    with open(root / "run/monitoring-cost-sync.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return CostSync(root).run()


if __name__ == "__main__":
    sys.exit(main())
