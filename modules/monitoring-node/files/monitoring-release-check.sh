#!/usr/bin/env bash
#
# monitoring-release-check: tell Prometheus whether a newer Amazon Linux 2023
# release exists, and since when. AL2023 locks packages to its image's release,
# so patching is an AMI bump; this is what says one is due.
#
# Writes node-exporter textfile metrics, every 6 hours and at boot
# (monitoring-release-check.timer), and exits 1 without touching them if dnf
# can't check:
#
#   monitoring_os_release_info{release="<running>"} 1
#   monitoring_os_release_update_available          0 or 1
#   monitoring_os_release_update_since_seconds      when one was first seen, or 0
set -euo pipefail

# The paths can be overridden, so tests/test-release-check.sh runs this script.
textfile_dir="${MONITORING_TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
state="${MONITORING_STATE_DIR:-/var/lib/monitoring}/release-update-since"
mkdir -p "$textfile_dir" "$(dirname "$state")"

running="$(rpm -q --qf '%{VERSION}' system-release 2>/dev/null || echo unknown)"

# Read what dnf says before deciding: it may exit non-zero when a newer release
# exists, so its status alone can't tell "newer" from "failed". A failed check
# (no network, say) changes nothing, so a blip never restarts the 7-day clock.
status=0
output="$(dnf -q check-release-update 2>&1)" || status=$?
if grep -qi 'newer release' <<< "$output"; then
  available=1
elif [[ "$status" == 0 ]]; then
  available=0
else
  echo "monitoring-release-check: dnf check-release-update failed (exit $status), metrics left as they were: $output" >&2
  exit 1
fi

if [[ "$available" == 1 ]]; then
  [[ -s "$state" ]] || date +%s > "$state"
  since="$(cat "$state")"
else
  rm -f "$state"
  since=0
fi

tmp="$(mktemp "${textfile_dir}/.os_release.XXXXXX")"
cat > "$tmp" <<PROM
# HELP monitoring_os_release_info The running Amazon Linux release.
# TYPE monitoring_os_release_info gauge
monitoring_os_release_info{release="${running}"} 1
# HELP monitoring_os_release_update_available Whether a newer Amazon Linux release exists (time for an AMI bump).
# TYPE monitoring_os_release_update_available gauge
monitoring_os_release_update_available ${available}
# HELP monitoring_os_release_update_since_seconds When a newer release was first seen, as a Unix time; 0 when none.
# TYPE monitoring_os_release_update_since_seconds gauge
monitoring_os_release_update_since_seconds ${since}
PROM
chmod 0644 "$tmp"
mv "$tmp" "${textfile_dir}/os_release.prom"
