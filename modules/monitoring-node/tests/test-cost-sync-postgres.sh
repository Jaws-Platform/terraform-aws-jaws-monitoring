#!/usr/bin/env bash
#
# Run the real monitoring-cost-sync against a real Postgres (the pinned image)
# and a fake S3 holding the normalizer's contract fixtures (csv-twin-1), and
# check what lands in the cost database and in the metrics. Needs docker and
# python3; nothing touches a cloud.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
mod="$(cd "$here/.." && pwd)"
twins="$(cd "$mod/../billing-normalizer/files/fixtures/twin" && pwd)"

fail() { echo "cost sync (postgres): $*" >&2; exit 1; }
command -v docker > /dev/null || fail "needs docker"
docker info > /dev/null 2>&1 || fail "docker isn't running"

image="$(sed -n 's/^ *"postgres" *= *"\(.*\)"$/\1/p' "$mod/bundle.tf")"
[[ -n "$image" ]] || fail "can't read the pinned postgres image from bundle.tf"

scratch="$(mktemp -d)"
container="cost-sync-pg-$$"
cleanup() {
  docker rm -f "$container" > /dev/null 2>&1 || true
  rm -rf "$scratch"
}
trap cleanup EXIT

# ------------------------------------------------------------- the node
root="$scratch/root"
bucket="$scratch/s3/acme-billing"
textfile="$scratch/textfile"
mkdir -p "$root/etc/monitoring" "$root/data/config/current/cost-sync" "$root/data/secrets" "$bucket" "$textfile" "$scratch/bin"
printf 'REGION=us-east-1\n' > "$root/etc/monitoring/node.env"
cat > "$root/data/config/current/cost-sync/config.json" << 'EOF'
{"bucket": "acme-billing", "prefix": "normalized", "providers": ["aws", "databricks"], "run_join_tags": ["RunId", "TaskId"]}
EOF
reader_password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
printf '%s' "$reader_password" > "$root/data/secrets/COST_READER_PASSWORD"
printf '#!/usr/bin/env bash\nexec python3 %q "$@"\n' "$here/fake_aws_s3.py" > "$scratch/bin/aws"
chmod +x "$scratch/bin/aws"

# The image first runs a temporary server on its socket only, to initialise;
# waiting on TCP waits for the real one.
docker run -d --name "$container" -e POSTGRES_USER=monitoring -e POSTGRES_PASSWORD=smoke -e POSTGRES_DB=grafana "$image" > /dev/null
for _ in $(seq 1 60); do
  docker exec "$container" pg_isready -h 127.0.0.1 -U monitoring -d grafana > /dev/null 2>&1 && break
  sleep 1
done
docker exec "$container" pg_isready -h 127.0.0.1 -U monitoring -d grafana > /dev/null 2>&1 || fail "postgres didn't start"

# The fixtures' runs are from 2026-11-20: judge them as of the next day.
export MONITORING_NOW=1795262400 # 2026-11-21T12:00:00Z
export MONITORING_ROOT="$root" MONITORING_TEXTFILE_DIR="$textfile" FAKE_S3_ROOT="$scratch/s3"
export MONITORING_PSQL="docker exec -i $container psql -U monitoring -v ON_ERROR_STOP=1"
export PATH="$scratch/bin:$PATH"

# COST_SYNC_PYTHON picks the interpreter (the node runs AL2023's Python 3.9).
sync() { "${COST_SYNC_PYTHON:-python3}" "$mod/files/monitoring-cost-sync.py"; }
q() { docker exec -i "$container" psql -U monitoring -d cost -X -At -c "$1"; }
metric() { awk -v m="$1" 'index($0, m) == 1 { print $NF }' "$textfile/cost_sync.prom"; }
expect() { # <case> <what> <got> <want>
  [[ "$3" == "$4" ]] || fail "$1: $2 is '$3', expected '$4'"
}
put() { # <fixture> <key>
  mkdir -p "$(dirname "$bucket/$2")"
  gzip -nc "$twins/$1" > "$bucket/$2"
}

aws_key="normalized/schema=focus-1.2/provider=aws/billing_period=2026-11/data.csv.gz"
databricks_key="normalized/schema=focus-1.2/provider=databricks/billing_period=2026-11/data.csv.gz"
runs_key="normalized/schema=runs-1/event_month=2026-11/data.csv.gz"

# before_any_data_the_clocks_start_at_the_first_run
sync || fail "before_any_data_the_clocks_start_at_the_first_run: an empty bucket made it fail"
first="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["first_run"])' "$root/data/cost-sync/state.json")"
expect before_any_data "newest AWS charge" "$(metric 'monitoring_cost_newest_charge_seconds{provider="aws"}')" "$first"
expect before_any_data "newest Databricks output" "$(metric 'monitoring_cost_newest_output_seconds{provider="databricks"}')" "$first"
expect before_any_data "normalizer last success" "$(metric monitoring_normalizer_last_success_seconds)" "$first"
echo "cost sync (postgres): before_any_data_the_clocks_start_at_the_first_run"

# first_sync_loads_every_output
put focus-aws.csv "$aws_key"
put focus-databricks.csv "$databricks_key"
put runs.csv "$runs_key"
mkdir -p "$bucket/normalized/_runs"
cat > "$bucket/normalized/_runs/latest.json" << 'EOF'
{"schema": "normalizer-run-1", "started_at": "2026-11-21T11:00:00Z", "ended_at": "2026-11-21T11:00:05Z", "status": "ok", "outputs": [], "warnings": ["w1"], "errors": []}
EOF
sync || fail "first_sync_loads_every_output: the run failed"
expect first_sync "cost.lines" "$(q 'select count(*) from cost.lines')" 3
expect first_sync "cost.run_events" "$(q 'select count(*) from cost.run_events')" 6
expect first_sync "cost.loads" "$(q 'select count(*) from cost.loads')" 3
expect first_sync "success" "$(metric monitoring_cost_sync_success)" 1
expect first_sync "outputs" "$(metric monitoring_cost_sync_outputs)" 3
expect first_sync "normalizer warnings" "$(metric monitoring_normalizer_warnings)" 1
expect first_sync "normalizer failed" "$(metric monitoring_normalizer_last_run_failed)" 0
expect first_sync "a NULL" "$(q "select count(*) from cost.lines where resource_id is null")" 1
expect first_sync "Databricks serverless" "$(q "select serverless from cost.lines where provider = 'databricks'")" t
expect first_sync "a tag" "$(q "select project from cost.lines where tags->>'RunId' = 'r1'")" braveheart-trainer
echo "cost sync (postgres): first_sync_loads_every_output"

# task_runs_merge_their_events_and_cost
expect task_runs "runs" "$(q 'select count(*) from cost.task_runs')" 4
expect task_runs "r1" "$(q "select outcome || ' ' || (ended_at is not null) from cost.task_runs where run_key = 'RunId=r1;TaskId=t1'")" "passed true"
expect task_runs "r4" "$(q "select outcome || ' ' || swept_reason from cost.task_runs where run_key = 'RunId=r4;TaskId=t4'")" "swept max hours exceeded"
expect task_runs "r2" "$(q "select coalesce(outcome, 'running') from cost.task_runs where run_key = 'RunId=r2;TaskId=t2'")" running
expect task_runs "r1's cost" "$(q "select billed_cost from cost.task_run_costs where run_key = 'RunId=r1;TaskId=t1'")" 12.5
echo "cost sync (postgres): task_runs_merge_their_events_and_cost"

# only_runs_past_their_limits_are_reported
expect limits "overdue runs" "$(grep -c '^monitoring_task_run_overdue_hours{' "$textfile/cost_sync.prom")" 1
grep -q '^monitoring_task_run_overdue_hours{.*run_key="RunId=r2;TaskId=t2"' "$textfile/cost_sync.prom" || fail "limits: r2 isn't the overdue run"
expect limits "runs over ceiling" "$(grep -c '^monitoring_task_run_over_ceiling_usd{' "$textfile/cost_sync.prom")" 1
expect limits "r1 over its ceiling" "$(metric 'monitoring_task_run_over_ceiling_usd{project="braveheart-trainer",run_key="RunId=r1;TaskId=t1"}')" 2.5
echo "cost sync (postgres): only_runs_past_their_limits_are_reported"

# an_old_run_over_its_ceiling_is_no_longer_reported
MONITORING_NOW=1797336000 sync || fail "an_old_run_over_its_ceiling_is_no_longer_reported: the run failed" # 2026-12-15
expect old_runs "runs over ceiling" "$(grep -c '^monitoring_task_run_over_ceiling_usd{' "$textfile/cost_sync.prom" || true)" 0
expect old_runs "overdue runs" "$(grep -c '^monitoring_task_run_overdue_hours{' "$textfile/cost_sync.prom")" 1
sync || fail "an_old_run_over_its_ceiling_is_no_longer_reported: the run failed"
echo "cost sync (postgres): an_old_run_over_its_ceiling_is_no_longer_reported"

# grafanas_reader_reads_and_nothing_else
reader() { docker exec -i -e "PGPASSWORD=$reader_password" "$container" psql -h 127.0.0.1 -U cost_reader -d cost -X -At -c "$1"; }
expect reader "SELECT" "$(reader 'select count(*) from cost.task_runs')" 4
if reader "insert into cost.lines (key, provider, period) values ('x', 'x', 'x')" > /dev/null 2>&1; then
  fail "grafanas_reader_reads_and_nothing_else: the reader could insert"
fi
echo "cost sync (postgres): grafanas_reader_reads_and_nothing_else"

# a_rewritten_output_replaces_its_rows
head -2 "$twins/focus-aws.csv" | gzip -nc > "$bucket/$aws_key"
sync || fail "a_rewritten_output_replaces_its_rows: the run failed"
expect rewritten "AWS rows" "$(q "select count(*) from cost.lines where key = '$aws_key'")" 1
expect rewritten "all rows" "$(q 'select count(*) from cost.lines')" 2
echo "cost sync (postgres): a_rewritten_output_replaces_its_rows"

# a_removed_output_loses_its_rows
rm "$bucket/$databricks_key"
sync || fail "a_removed_output_loses_its_rows: the run failed"
expect removed "Databricks rows" "$(q "select count(*) from cost.lines where provider = 'databricks'")" 0
expect removed "its load" "$(q "select count(*) from cost.loads where key = '$databricks_key'")" 0
echo "cost sync (postgres): a_removed_output_loses_its_rows"

# a_schema_version_change_rebuilds
before="$(q 'select max(loaded_at) from cost.loads')"
q "update cost.meta set value = '0' where name = 'schema_version'" > /dev/null
sync || fail "a_schema_version_change_rebuilds: the run failed"
expect rebuilt "reloaded outputs" "$(q "select count(*) from cost.loads where loaded_at > '$before'")" 2
expect rebuilt "version" "$(q "select value from cost.meta where name = 'schema_version'")" 3
expect rebuilt "rows" "$(q 'select count(*) from cost.lines')" 1
echo "cost sync (postgres): a_schema_version_change_rebuilds"

# ------------------------------------------------------- the cost model
# Fresh tables, the model's rows, and budgets through config.json.
q 'truncate cost.lines, cost.run_events, cost.loads' > /dev/null
rm -rf "$bucket/normalized"
docker exec -i "$container" psql -U monitoring -d cost -X -q -v ON_ERROR_STOP=1 < "$here/cost_model_rows.sql" > /dev/null
budgets() { # <projects json>
  printf '{"bucket": "acme-billing", "prefix": "normalized", "providers": ["aws", "databricks"], "run_join_tags": ["RunId", "TaskId"], "budgets": {"total": 400, "projects": %s, "accounts": {"production": 1000}}}' "$1" \
    > "$root/data/config/current/cost-sync/config.json"
}
budgets '{"alpha": 300, "gamma": 50}'
sync || fail "the cost model: the run failed"
at() { # <cost.now> <query>
  docker exec -i "$container" psql -U monitoring -d cost -X -q -At -v ON_ERROR_STOP=1 <<< "SET cost.now = '$1'; $2"
}
now='2026-11-21T12:00:00Z'

# complete_days_are_48_hours_old
expect complete_days "Nov 18" "$(at "$now" "select bool_and(complete) from cost.daily where day = '2026-11-18'")" t
expect complete_days "Nov 19" "$(at "$now" "select bool_or(complete) from cost.daily where day = '2026-11-19'")" f
expect complete_days "as of" "$(at "$now" 'select day from cost.as_of')" 2026-11-18
echo "cost sync (postgres): complete_days_are_48_hours_old"

# the_forecast_uses_the_last_7_complete_days
expect forecast "alpha" "$(at "$now" "select concat_ws(' ', round(complete_mtd::numeric, 2), round(avg7::numeric, 2), days_left, round(forecast::numeric, 2), round(forecast_percent::numeric, 2)) from cost.month_to_date where scope = 'project' and name = 'alpha'")" "180.00 10.00 12 340.00 113.33"
echo "cost sync (postgres): the_forecast_uses_the_last_7_complete_days"

# the_forecast_is_never_below_the_spend (alpha's $50 on partial Nov 21 counts in full)
expect never_below "every scope" "$(at "$now" 'select bool_and(forecast >= mtd) from cost.month_to_date')" t
echo "cost sync (postgres): the_forecast_is_never_below_the_spend"

# a_month_long_charge_is_spent_but_not_a_days_spend
expect month_long "the total's month" "$(at "$now" "select round(mtd::numeric, 2) from cost.month_to_date where scope = 'total'")" 379.60
expect month_long "the total's Nov 21" "$(at "$now" "select round(spend::numeric, 2) from cost.anomalies where kind = 'total' and day = '2026-11-21'")" 63.80
expect month_long "new untagged" "$(at "$now" "select count(*) from cost.untagged_new where service = 'AWS Support (Business)' and is_new")" 0
echo "cost sync (postgres): a_month_long_charge_is_spent_but_not_a_days_spend"

# the_forecast_carries_across_a_month_boundary
expect boundary "alpha" "$(at '2026-11-02T06:00:00Z' "select concat_ws(' ', round(complete_mtd::numeric, 2), round(avg7::numeric, 2), days_left, round(forecast::numeric, 2)) from cost.month_to_date where scope = 'project' and name = 'alpha'")" "0.00 10.00 30 300.00"
echo "cost sync (postgres): the_forecast_carries_across_a_month_boundary"

# budgets_match_by_id_or_name_and_show_with_no_spend
expect budgets "the account" "$(at "$now" "select round(budget::numeric) from cost.month_to_date where scope = 'account' and name = '570327089884'")" 1000
expect budgets "gamma" "$(at "$now" "select concat_ws(' ', round(mtd::numeric, 2), round(used_percent::numeric, 2)) from cost.month_to_date where scope = 'project' and name = 'gamma'")" "0.00 0.00"
expect budgets "the total" "$(at "$now" "select round(budget::numeric) from cost.month_to_date where scope = 'total'")" 400
echo "cost sync (postgres): budgets_match_by_id_or_name_and_show_with_no_spend"

# a_new_project_is_not_an_anomaly_of_infinity
expect anomaly "alpha" "$(at "$now" "select concat_ws(' ', day, round(median14::numeric, 2), round(ratio::numeric, 2), round(excess::numeric, 2)) from cost.anomalies where kind = 'project' and name = 'alpha'")" "2026-11-21 10.00 5.00 40.00"
expect anomaly "beta" "$(at "$now" "select concat_ws(' ', round(median14::numeric, 2), coalesce(ratio::text, 'null')) from cost.anomalies where kind = 'project' and name = 'beta'")" "0.00 null"
expect anomaly "the total" "$(at "$now" "select concat_ws(' ', round(median14::numeric, 2), ratio > 4) from cost.anomalies where kind = 'total' and day = '2026-11-21'")" "13.60 t"
echo "cost sync (postgres): a_new_project_is_not_an_anomaly_of_infinity"

# a_lagging_providers_day_is_judged_when_it_lands
expect lagging "dbx on Nov 20" "$(at "$now" "select concat_ws(' ', round(median14::numeric, 2), ratio > 4) from cost.anomalies where kind = 'project' and name = 'dbx' and day = '2026-11-20'")" "3.00 t"
expect lagging "the days judged" "$(at "$now" "select string_agg(distinct day::text, ',' order by day::text) from cost.anomalies")" "2026-11-19,2026-11-20,2026-11-21"
echo "cost sync (postgres): a_lagging_providers_day_is_judged_when_it_lands"

# steady_untagged_spend_is_new_only_once
expect untagged "S3" "$(at "$now" "select is_new from cost.untagged_new where service = 'Amazon Simple Storage Service'")" t
expect untagged "VPC" "$(at "$now" "select is_new from cost.untagged_new where service = 'Amazon Virtual Private Cloud'")" f
expect untagged "a late start" "$(at "$now" "select concat_ws(' ', is_new, first_day, round(spend::numeric, 2)) from cost.untagged_new where service = 'Amazon CloudWatch'")" "t 2026-11-20 1.40"
expect untagged "tax" "$(at "$now" "select count(*) from cost.untagged where service = 'Tax'")" 0
echo "cost sync (postgres): steady_untagged_spend_is_new_only_once"

# budgets_are_rewritten_every_run
budgets '{"alpha": 300}'
sync || fail "budgets_are_rewritten_every_run: the run failed"
expect rewritten_budgets "gamma" "$(q "select count(*) from cost.budgets where name = 'gamma'")" 0
expect rewritten_budgets "alpha" "$(q "select round(monthly_usd::numeric) from cost.budgets where scope = 'project' and name = 'alpha'")" 300
echo "cost sync (postgres): budgets_are_rewritten_every_run"

# the_model_reads_only_its_window: two years of older rows (14,600) must not be
# read again by every view, every 5 minutes. Rows read are the plan's rows from
# cost.lines, kept or filtered out, over every loop.
docker exec -i "$container" psql -U monitoring -d cost -X -q -v ON_ERROR_STOP=1 > /dev/null << 'SQL'
INSERT INTO cost.lines (key, provider, period, provider_name, sub_account_id, sub_account_name, charge_period_start,
                        charge_category, service_name, billed_cost, tags, project)
SELECT 'test/filler', 'aws', to_char(d, 'YYYY-MM'), 'AWS', '570327089884', 'production', d, 'Usage',
       'Amazon Elastic Compute Cloud', 1, '{"Project": "filler"}', 'filler'
FROM generate_series('2024-10-01T00:00:00Z'::timestamptz, '2026-09-30T00:00:00Z', interval '1 day') AS d,
     generate_series(1, 20) AS n;
ANALYZE cost.lines;
SQL
read_rows() { # <view>
  at "$now" "CREATE FUNCTION pg_temp.lines_read(q text) RETURNS bigint LANGUAGE plpgsql AS \$\$
DECLARE plan jsonb;
BEGIN
  EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON) ' || q INTO plan;
  RETURN (SELECT coalesce(sum(((n->>'Actual Rows')::numeric + coalesce((n->>'Rows Removed by Filter')::numeric, 0))
                              * (n->>'Actual Loops')::numeric), 0)::bigint
          FROM jsonb_path_query(plan, 'strict \$.**') AS n
          WHERE jsonb_typeof(n) = 'object' AND n->>'Relation Name' = 'lines');
END \$\$;
SELECT pg_temp.lines_read('SELECT * FROM $1');"
}
for view in cost.month_to_date cost.anomalies cost.untagged_new cost.as_of; do
  got="$(read_rows "$view")"
  [ "$got" -lt 1000 ] || fail "the_model_reads_only_its_window: $view read $got rows of cost.lines"
done
echo "cost sync (postgres): the_model_reads_only_its_window"

# ------------------------------------------------------- the cost views
# Fresh tables and the views' rows (tests/cost_views_rows.sql).
q 'truncate cost.lines, cost.run_events, cost.loads' > /dev/null
docker exec -i "$container" psql -U monitoring -d cost -X -q -v ON_ERROR_STOP=1 < "$here/cost_views_rows.sql" > /dev/null
views_config() { # [databricks workspace tag]
  printf '{"bucket": "acme-billing", "prefix": "normalized", "providers": ["aws", "databricks"], "run_join_tags": ["RunId", "TaskId"], "databricks_workspace_tag": "%s"}' "${1:-Workspace}" \
    > "$root/data/config/current/cost-sync/config.json"
}
views_config
sync || fail "the cost views: the run failed"

# the_daily_view_carries_the_component
expect component "web-app on Nov 20" "$(at "$now" "select string_agg(component || '=' || billed_cost, ',' order by component) from cost.daily where project = 'web-app' and day = '2026-11-20'")" "api=1,site=2"
echo "cost sync (postgres): the_daily_view_carries_the_component"

# databricks_daily_names_products_and_counts_dbus
expect databricks "ws-1" "$(at "$now" "select string_agg(concat_ws(' ', product, serverless, quantity, list_cost), ',' order by product) from cost.databricks_daily where workspace_id = 'ws-1'")" "ALL_PURPOSE f 4 2.2,JOBS t 10 3.5"
echo "cost sync (postgres): databricks_daily_names_products_and_counts_dbus"

# the_all_in_adds_the_workspaces_aws_rows_in_any_tag_key_form
expect all_in "Nov 20" "$(at "$now" "select concat_ws(' ', round(databricks_cost::numeric, 2), round(aws_cost::numeric, 2), round(all_in_cost::numeric, 2)) from cost.databricks_all_in where workspace = 'braveheart-prod' and day = '2026-11-20'")" "5.70 1.50 7.20"
expect all_in "Nov 19" "$(at "$now" "select concat_ws(' ', round(databricks_cost::numeric, 2), round(aws_cost::numeric, 2), round(all_in_cost::numeric, 2)) from cost.databricks_all_in where workspace = 'braveheart-prod' and day = '2026-11-19'")" "0.00 0.10 0.10"
echo "cost sync (postgres): the_all_in_adds_the_workspaces_aws_rows_in_any_tag_key_form"

# a_workspace_without_a_name_is_shown_by_its_id
expect all_in_id "ws-2" "$(at "$now" "select concat_ws(' ', round(databricks_cost::numeric, 2), round(aws_cost::numeric, 2), round(all_in_cost::numeric, 2)) from cost.databricks_all_in where workspace = 'ws-2' and day = '2026-11-20'")" "1.00 0.00 1.00"
echo "cost sync (postgres): a_workspace_without_a_name_is_shown_by_its_id"

# the_workspace_tag_is_the_callers
views_config DatabricksWorkspace
sync || fail "the_workspace_tag_is_the_callers: the run failed"
expect workspace_tag "AWS on Nov 20" "$(at "$now" "select round(aws_cost::numeric, 2) from cost.databricks_all_in where workspace = 'braveheart-prod' and day = '2026-11-20'")" 0.00
views_config
sync || fail "the_workspace_tag_is_the_callers: the run back failed"
echo "cost sync (postgres): the_workspace_tag_is_the_callers"

# a_run_matches_its_cost_rows_in_any_tag_key_form
expect key_forms "billed per run" "$(at "$now" "select string_agg(round(billed_cost::numeric, 2)::text, ',' order by run_key) from cost.task_run_costs")" "4.80,1.70,0.00,16.00"
echo "cost sync (postgres): a_run_matches_its_cost_rows_in_any_tag_key_form"

# a_finished_run_shows_its_bill
expect finished "R1" "$(at "$now" "select concat_ws(' ', source, outcome, estimated, round(cost::numeric, 2), hours, gpu_hours, round(on_demand_cost::numeric, 2), round(ceiling_percent::numeric, 2), round(cost_per_gpu_hour::numeric, 2), pr, commit) from cost.runs where run_key = 'RunId=100-1;TaskId=net-v12'")" "record passed f 4.80 5 5 10.00 9.60 0.96 #88 a1b2c3d"
echo "cost sync (postgres): a_finished_run_shows_its_bill"

# a_run_is_estimated_until_its_last_day_is_complete
expect estimated "R2 now" "$(at "$now" "select concat_ws(' ', estimated, round(cost::numeric, 2), round(billed_cost::numeric, 2)) from cost.runs where run_key = 'RunId=101-1;TaskId=net-v12'")" "t 2.00 1.70"
expect estimated "R2 later" "$(at '2026-11-23T12:00:00Z' "select concat_ws(' ', estimated, round(cost::numeric, 2), round(billed_cost::numeric, 2)) from cost.runs where run_key = 'RunId=101-1;TaskId=net-v12'")" "f 1.70 1.70"
echo "cost sync (postgres): a_run_is_estimated_until_its_last_day_is_complete"

# a_running_run_is_estimated_to_now
expect running "R3" "$(at "$now" "select concat_ws(' ', outcome, estimated, hours, round(cost::numeric, 2), gpu_hours, coalesce(cost_per_gpu_hour::text, 'null')) from cost.runs where run_key = 'RunId=102-1;TaskId=datagen'")" "running t 6 3.00 0 null"
echo "cost sync (postgres): a_running_run_is_estimated_to_now"

# a_swept_run_ends_when_it_was_swept
expect swept "R4" "$(at "$now" "select concat_ws(' ', outcome, ended_at, hours, round(cost::numeric, 2), round(ceiling_percent::numeric, 2)) from cost.runs where run_key = 'RunId=103-1;TaskId=probe'")" "swept 2026-11-10 08:00:00+00 8 16.00 80.00"
echo "cost sync (postgres): a_swept_run_ends_when_it_was_swept"

# a_run_without_a_record_is_built_from_its_tags
expect tag_only "R5" "$(at "$now" "select concat_ws(' ', source, workflow, profile, campaign, hours, round(cost::numeric, 2)) from cost.runs where run_key = 'RunId=99-1;TaskId=old'")" "tags train gpu net-v11 3.5 7.00"
echo "cost sync (postgres): a_run_without_a_record_is_built_from_its_tags"

# a_recorded_run_appears_once
expect once "R1" "$(at "$now" "select count(*) from cost.runs where run_key = 'RunId=100-1;TaskId=net-v12'")" 1
expect once "all runs" "$(at "$now" "select count(*) from cost.runs")" 5
echo "cost sync (postgres): a_recorded_run_appears_once"

# campaigns_add_up_their_runs
expect campaigns "net-v12" "$(at "$now" "select concat_ws(' ', project, runs, passed, failed, interrupted, instance_hours, gpu_hours, round(cost::numeric, 2), round(on_demand_cost::numeric, 2), round(saved::numeric, 2), round(saved_percent::numeric, 2), round(cost_per_passed_run::numeric, 2)) from cost.campaigns where campaign = 'net-v12'")" "braveheart-trainer 2 1 0 1 7 7 6.80 14.00 7.20 51.43 6.80"
expect campaigns "net-v11" "$(at "$now" "select coalesce(cost_per_passed_run::text, 'null') from cost.campaigns where campaign = 'net-v11'")" null
echo "cost sync (postgres): campaigns_add_up_their_runs"

echo "cost sync (postgres): OK"
