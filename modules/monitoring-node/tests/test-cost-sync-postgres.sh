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

docker run -d --name "$container" -e POSTGRES_USER=monitoring -e POSTGRES_PASSWORD=smoke -e POSTGRES_DB=grafana "$image" > /dev/null
for _ in $(seq 1 60); do
  docker exec "$container" pg_isready -U monitoring -d grafana > /dev/null 2>&1 && break
  sleep 1
done
docker exec "$container" pg_isready -U monitoring -d grafana > /dev/null 2>&1 || fail "postgres didn't start"

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

echo "cost sync (postgres): OK"
