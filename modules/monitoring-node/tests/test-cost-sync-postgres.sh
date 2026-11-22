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
expect rebuilt "version" "$(q "select value from cost.meta where name = 'schema_version'")" 1
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
expect forecast "alpha" "$(at "$now" "select concat_ws(' ', round(complete_mtd::numeric, 2), round(avg7::numeric, 2), days_left, round(forecast::numeric, 2), round(forecast_percent::numeric, 2)) from cost.month_to_date where scope = 'project' and name = 'alpha'")" "180.00 10.00 12 300.00 100.00"
echo "cost sync (postgres): the_forecast_uses_the_last_7_complete_days"

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
expect anomaly "the total" "$(at "$now" "select concat_ws(' ', round(spend::numeric, 2), round(median14::numeric, 2), ratio > 4) from cost.anomalies where kind = 'total'")" "62.60 10.60 t"
echo "cost sync (postgres): a_new_project_is_not_an_anomaly_of_infinity"

# steady_untagged_spend_is_new_only_once
expect untagged "S3" "$(at "$now" "select round(prior_spend::numeric, 2) from cost.untagged_new where service = 'Amazon Simple Storage Service'")" 0.00
expect untagged "VPC" "$(at "$now" "select prior_spend > 0 from cost.untagged_new where service = 'Amazon Virtual Private Cloud'")" t
expect untagged "tax" "$(at "$now" "select count(*) from cost.untagged where service = 'Tax'")" 0
echo "cost sync (postgres): steady_untagged_spend_is_new_only_once"

# budgets_are_rewritten_every_run
budgets '{"alpha": 300}'
sync || fail "budgets_are_rewritten_every_run: the run failed"
expect rewritten_budgets "gamma" "$(q "select count(*) from cost.budgets where name = 'gamma'")" 0
expect rewritten_budgets "alpha" "$(q "select round(monthly_usd::numeric) from cost.budgets where scope = 'project' and name = 'alpha'")" 300
echo "cost sync (postgres): budgets_are_rewritten_every_run"

echo "cost sync (postgres): OK"
