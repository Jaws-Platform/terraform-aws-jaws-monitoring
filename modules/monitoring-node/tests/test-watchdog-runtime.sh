#!/usr/bin/env bash
# Run the watchdog's unit tests inside the AWS Lambda Python 3.13 runtime it is
# deployed to (the public base image, pinned by digest), so the zone database
# (zoneinfo with America/Denver) and boto3 are the runtime's own, not the
# machine's. No AWS calls: the tests use fake clients.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
mod="$(cd "$here/.." && pwd)"
image="public.ecr.aws/lambda/python:3.13@sha256:acb9955991db82a4a68d5189725276db3a3b1e45b6b52f879c9c1c08fdeb5ff9"

fail() {
  echo "watchdog runtime: $*" >&2
  exit 1
}

command -v docker > /dev/null || fail "docker is required"

docker run --rm --entrypoint python3 -v "$mod/files:/work:ro" -w /work "$image" -c '
import sys, zoneinfo, boto3
zoneinfo.ZoneInfo("America/Denver")
print("watchdog runtime: Python", sys.version.split()[0], "with zoneinfo and boto3", boto3.__version__)
' || fail "the runtime lacks the zone database or boto3"

if ! out="$(docker run --rm --entrypoint python3 -v "$mod/files:/work:ro" -w /work -e PYTHONDONTWRITEBYTECODE=1 \
  "$image" -m unittest -q test_watchdog 2>&1)"; then
  echo "$out" >&2
  fail "the unit tests failed in the runtime"
fi
echo "$out" | tail -1

echo "watchdog runtime: OK"
