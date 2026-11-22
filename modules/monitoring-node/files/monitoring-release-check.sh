#!/usr/bin/env bash
#
# monitoring-release-check: tell Prometheus whether a newer Amazon Linux 2023
# release exists, and since when. AL2023 locks packages to its image's release,
# so patching is an AMI bump; this is what says one is due.
#
# Writes node-exporter textfile metrics, every 6 hours and at boot
# (monitoring-release-check.timer):
#
#   monitoring_os_release_info{release="<running>"} 1
#   monitoring_os_release_update_available          0 or 1
#   monitoring_os_release_update_since_seconds      when one was first seen, or 0
set -euo pipefail

textfile_dir=/var/lib/node_exporter/textfile
state=/var/lib/monitoring/release-update-since
mkdir -p "$textfile_dir" "$(dirname "$state")"

running="$(rpm -q --qf '%{VERSION}' system-release 2>/dev/null || echo unknown)"

available=0
if dnf -q check-release-update 2>&1 | grep -qi 'newer release'; then
  available=1
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
