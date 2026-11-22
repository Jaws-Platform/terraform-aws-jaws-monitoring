#!/usr/bin/env bash
#
# Load what the grafana module renders into the pinned Grafana, and check that
# Grafana reports exactly what was rendered. Grafana validates provisioning only
# at startup, and one bad file can take all of it down, so this is the test the
# Terraform assertions can't be.
#
#   phase 1  render, check every PromQL query with promtool, start Grafana on
#            the files next to a Postgres that the real cost-sync has set up,
#            compare its API with the files (the Cost data source must connect
#            and read), and read its logs
#   phase 2  render a changed configuration (credits and Slack switched off,
#            a domain added, files removed), start a new Grafana on the same
#            database, compare again: what was removed must be gone
#
# Needs docker, terraform and python3; nothing touches a cloud. The Grafana and
# Prometheus images are the ones bundle.tf pins.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
mod="$(cd "$here/.." && pwd)"

fail() { echo "grafana smoke: $*" >&2; exit 1; }

for tool in docker terraform python3 curl; do
  command -v "$tool" > /dev/null || fail "needs $tool"
done
docker info > /dev/null 2>&1 || fail "docker isn't running"

pinned() { sed -n "s/^ *\"$1\" *= *\"\(.*\)\"$/\1/p" "$mod/bundle.tf"; }
grafana_image="$(pinned grafana)"
prometheus_image="$(pinned prometheus)"
postgres_image="$(pinned postgres)"
[[ -n "$grafana_image" && -n "$prometheus_image" && -n "$postgres_image" ]] || fail "can't read the pinned images from bundle.tf"

scratch="$(mktemp -d)"
name="grafana-smoke-$$"
volume="$name-data"
password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
reader_password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
network="$name-net"
postgres="$name-pg"

cleanup() {
  docker rm -f "$name" "$postgres" > /dev/null 2>&1 || true
  docker volume rm -f "$volume" > /dev/null 2>&1 || true
  docker network rm "$network" > /dev/null 2>&1 || true
  rm -rf "$scratch"
}
trap cleanup EXIT

# The module's arguments in each phase, as HCL.
# Any valid numbers do here; the defaults live in variables.tf.
thresholds='  thresholds = {
    cpu_percent             = { warning = 60, critical = 85 }
    cpu_credits_percent     = { warning = 25, critical = 5 }
    memory_percent          = { warning = 70, critical = 90 }
    swap_percent            = { warning = 25, critical = 75 }
    disk_percent            = { warning = 70, critical = 90 }
    disk_full_days          = { warning = 7, critical = 2 }
    inodes_percent          = { warning = 70, critical = 90 }
    prometheus_size_percent = { warning = 85 }
    prometheus_history_days = { warning = 90 }
    container_restarts      = { warning = 1, critical = 3 }
    tls_days                = { warning = 14, critical = 3 }
    os_release_update_days  = { warning = 7 }
    normalizer_hours          = { warning = 3, critical = 12 }
    aws_charge_days           = { warning = 3, critical = 5 }
    databricks_delivery_hours = { warning = 36, critical = 60 }
    cost_sync_hours           = { warning = 2, critical = 6 }
  }'

phase1_args() {
  cat << EOF
  region            = "us-east-1"
  instance_id       = "i-0123456789abcdef0"
  instance_type     = "t9g.medium"
  domain            = null
$thresholds
  slack = {
    channels = { platform = "/acme/monitoring/slack/platform", costs = "/acme/monitoring/slack/costs" }
    routes   = { host = "platform", pipeline = "platform", cost = "costs" }
  }
  cost = { providers = ["aws", "databricks"] }
  extra_dashboards  = { "Extra/extra.json" = file("$here/fixtures/extra-dashboard.json") }
  extra_alert_rules = {
    smoke = file("$here/fixtures/extra-rule.yaml")
    # A \$ in a query model and an annotation, which the validator allows:
    # Grafana must store it as written.
    math = file("$here/fixtures/extra-rule-math.yaml")
  }
EOF
}

phase2_args() {
  cat << EOF
  region            = "us-east-1"
  instance_id       = "i-0123456789abcdef0"
  instance_type     = "m7g.medium"
  domain            = "grafana.example.com"
$thresholds
  extra_alert_rules = {
    smoke = "apiVersion: 1\ndeleteRules:\n  - orgId: 1\n    uid: extra-up-critical\n"
    math  = "apiVersion: 1\ndeleteRules:\n  - orgId: 1\n    uid: extra-math-warning\n"
  }
EOF
}

render() { # <phase> <args>
  local root="$scratch/$1/root"
  mkdir -p "$root"
  cat > "$root/main.tf" << EOF
module "grafana" {
  source = "$mod/grafana"
$2
}

output "files" {
  value = module.grafana.files
}
EOF
  terraform -chdir="$root" init -input=false > /dev/null
  terraform -chdir="$root" apply -auto-approve -input=false > /dev/null
  terraform -chdir="$root" output -json files > "$scratch/$1/files.json"
  python3 "$here/grafana_smoke.py" write "$scratch/$1/files.json" "$scratch/$1/release"
}

check_queries() { # <phase>
  local q="$scratch/$1/queries"
  mkdir -p "$q"
  count="$(python3 "$here/grafana_smoke.py" queries "$scratch/$1/release" "$q/queries.yml")"
  if [[ "$count" == 0 ]]; then
    echo "grafana smoke ($1): no PromQL queries to check"
    return 0
  fi
  docker run --rm --entrypoint promtool -v "$q:/q:ro" "$prometheus_image" check rules /q/queries.yml > "$q/promtool.log" 2>&1 \
    || { cat "$q/promtool.log" >&2; fail "promtool rejects a query ($1)"; }
  echo "grafana smoke ($1): promtool parses all $count PromQL queries"
}

# A Postgres on Grafana's network (as "postgres"), with the cost database and
# its read-only user made by the real cost-sync over an empty fake bucket.
start_postgres() {
  docker network create "$network" > /dev/null
  docker run -d --name "$postgres" --network "$network" --network-alias postgres \
    -e POSTGRES_USER=monitoring -e POSTGRES_PASSWORD=smoke -e POSTGRES_DB=grafana "$postgres_image" > /dev/null
  for _ in $(seq 1 60); do
    docker exec "$postgres" pg_isready -h 127.0.0.1 -U monitoring -d grafana > /dev/null 2>&1 && break
    sleep 1
  done
  local node="$scratch/cost-node"
  mkdir -p "$node/root/data/config/current/cost-sync" "$node/root/data/secrets" "$node/s3/acme-billing" "$node/bin" "$node/textfile"
  printf '{"bucket": "acme-billing", "prefix": "normalized", "providers": ["aws"], "run_join_tags": ["RunId", "TaskId"]}' \
    > "$node/root/data/config/current/cost-sync/config.json"
  printf '%s' "$reader_password" > "$node/root/data/secrets/COST_READER_PASSWORD"
  printf '#!/usr/bin/env bash\nexec python3 %q "$@"\n' "$here/fake_aws_s3.py" > "$node/bin/aws"
  chmod +x "$node/bin/aws"
  PATH="$node/bin:$PATH" MONITORING_ROOT="$node/root" MONITORING_TEXTFILE_DIR="$node/textfile" FAKE_S3_ROOT="$node/s3" \
    MONITORING_PSQL="docker exec -i $postgres psql -U monitoring -v ON_ERROR_STOP=1" \
    python3 "$mod/files/monitoring-cost-sync.py" || fail "cost-sync couldn't set up the cost database"
}

start_grafana() { # <phase>
  local release="$scratch/$1/release" env=()
  for var in $(python3 "$here/grafana_smoke.py" env "$release"); do
    env+=(-e "$var=https://hooks.slack.invalid/smoke")
  done
  env+=(-e "COST_READER_PASSWORD=$reader_password")
  docker rm -f "$name" > /dev/null 2>&1 || true
  docker run -d --name "$name" \
    -e GF_SECURITY_ADMIN_USER=smoke -e "GF_SECURITY_ADMIN_PASSWORD=$password" \
    -e GF_ANALYTICS_REPORTING_ENABLED=false -e GF_ANALYTICS_CHECK_FOR_UPDATES=false \
    ${env[@]+"${env[@]}"} \
    -v "$release/grafana/provisioning:/etc/grafana/provisioning:ro" \
    -v "$release/grafana/dashboards:/var/lib/grafana/dashboards:ro" \
    -v "$volume:/var/lib/grafana" \
    --network "$network" -p 127.0.0.1::3000 "$grafana_image" > /dev/null
  url="http://$(docker port "$name" 3000/tcp | head -1)"
  for _ in $(seq 1 60); do
    curl -fsS "$url/api/health" > /dev/null 2>&1 && return 0
    sleep 2
  done
  docker logs "$name" 2>&1 | tail -40 >&2
  fail "Grafana didn't become healthy ($1)"
}

check_grafana() { # <phase>
  python3 "$here/grafana_smoke.py" compare "$scratch/$1/release" "$url" smoke "$password" "$1" \
    || { docker logs "$name" 2>&1 | grep -iE 'level=(error|warn)' | tail -20 >&2; fail "Grafana doesn't match what was rendered ($1)"; }
  if docker logs "$name" 2>&1 | grep 'level=error' | grep -qi 'provision'; then
    docker logs "$name" 2>&1 | grep 'level=error' | grep -i 'provision' >&2
    fail "Grafana logged a provisioning error ($1)"
  fi
}

start_postgres

for phase in phase1 phase2; do
  render "$phase" "$("${phase}_args")"
  check_queries "$phase"
  start_grafana "$phase"
  check_grafana "$phase"
done

echo "grafana smoke: OK"
