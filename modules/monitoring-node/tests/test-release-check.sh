#!/usr/bin/env bash
#
# Run the real monitoring-release-check against fake dnf and rpm: a newer
# release must be reported whatever dnf exits with, its first sighting kept,
# and a failed check (no network) must leave the 7-day clock alone.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../files/monitoring-release-check.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

mkdir -p "$scratch/bin"
cat > "$scratch/bin/rpm" << 'EOF'
#!/usr/bin/env bash
printf '2023.12.20261026'
EOF
cat > "$scratch/bin/dnf" << 'EOF'
#!/usr/bin/env bash
case "${FAKE_DNF:?}" in
  newer) echo 'WARNING: A newer release of "Amazon Linux" is available.'; exit 100 ;;
  none) exit 0 ;;
  error) echo 'Error: Failed to download metadata for repo' >&2; exit 1 ;;
esac
EOF
chmod +x "$scratch/bin/rpm" "$scratch/bin/dnf"

export PATH="$scratch/bin:$PATH"
export MONITORING_TEXTFILE_DIR="$scratch/textfile" MONITORING_STATE_DIR="$scratch/state"
prom="$MONITORING_TEXTFILE_DIR/os_release.prom"

fail() { echo "release check: $*" >&2; exit 1; }
check() { FAKE_DNF="$1" bash "$script"; }
metric() { awk -v m="$1" '$1 == m { print $2 }' "$prom"; }
info_line() { grep -qF 'monitoring_os_release_info{release="2023.12.20261026"} 1' "$prom" || fail "$1: the running release isn't reported"; }

# 1. dnf reports a newer release and exits 100.
check newer || fail "case 1: the check failed on a newer release"
[[ "$(metric monitoring_os_release_update_available)" == 1 ]] || fail "case 1: a newer release (dnf exits 100) must read as available"
since="$(metric monitoring_os_release_update_since_seconds)"
[[ "$since" != 0 ]] || fail "case 1: when it was first seen must be recorded"
info_line "case 1"

# 2. Still there an hour later (here, a second): the first sighting is kept.
sleep 1
check newer || fail "case 2: the check failed"
[[ "$(metric monitoring_os_release_update_since_seconds)" == "$since" ]] || fail "case 2: the first sighting must be kept"

# 3. dnf can't reach its repositories: nothing changes, and the run fails.
before="$(cat "$prom")"
if check error 2> /dev/null; then
  fail "case 3: a failed dnf must fail the run"
fi
[[ "$(cat "$prom")" == "$before" ]] || fail "case 3: a failed dnf must leave the metrics as they were"
[[ -s "$MONITORING_STATE_DIR/release-update-since" ]] || fail "case 3: a failed dnf must keep the first sighting"

# 4. No newer release: nothing available, the clock cleared.
check none || fail "case 4: the check failed"
[[ "$(metric monitoring_os_release_update_available)" == 0 ]] || fail "case 4: nothing newer must read as 0"
[[ "$(metric monitoring_os_release_update_since_seconds)" == 0 ]] || fail "case 4: since must be 0"
[[ ! -e "$MONITORING_STATE_DIR/release-update-since" ]] || fail "case 4: the first sighting must be cleared"
info_line "case 4"

echo "release check: OK"
