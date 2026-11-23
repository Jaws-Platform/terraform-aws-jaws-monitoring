#!/usr/bin/env bash
# Run the bootstrap's data-volume format command, exactly as written in
# files/monitoring-bootstrap.sh, inside Amazon Linux 2023 (the node's OS,
# pinned by digest) against a file-backed disk. AL2023's mkfs.xfs is what
# formats a new data volume at first boot; if it rejects the command (an XFS
# label over 12 characters, say), the bootstrap fails and nothing starts.
# No AWS calls.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
mod="$(cd "$here/.." && pwd)"
image="amazonlinux:2023@sha256:9cf762f5099b606bcd851391317af7cd75b11363c4816ebcb5e91292dd5736a7"

fail() {
  echo "bootstrap runtime: $*" >&2
  exit 1
}

command -v docker > /dev/null || fail "docker is required"

lines="$(grep -E '^[[:space:]]*mkfs\.xfs ' "$mod/files/monitoring-bootstrap.sh" || true)"
[[ "$(printf '%s\n' "$lines" | grep -c .)" == 1 ]] || fail "expected one mkfs.xfs line in the bootstrap, found: ${lines:-none}"
mkfs_line="$(echo "$lines" | sed -E 's/^[[:space:]]+//')"

if ! out="$(docker run --rm -e MKFS_LINE="$mkfs_line" --entrypoint bash "$image" -c '
set -euo pipefail
dnf install -q -y xfsprogs > /dev/null 2>&1
echo "bootstrap runtime: $(rpm -q xfsprogs)"
truncate -s 1G /tmp/data.img
device=/tmp/data.img
eval "$MKFS_LINE" > /dev/null
want="$(echo "$MKFS_LINE" | sed -nE "s/.*-L ([^ ]+).*/\1/p")"
got="$(xfs_admin -l "$device" | sed -nE "s/^label = \"(.*)\"$/\1/p")"
[[ "$got" == "$want" ]] || { echo "label is \"$got\", want \"$want\""; exit 1; }
echo "bootstrap runtime: formatted with label $got"
' 2>&1)"; then
  echo "$out" >&2
  fail "the bootstrap cannot format a new data volume: $mkfs_line"
fi
echo "$out"

echo "bootstrap runtime: OK"
