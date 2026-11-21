#!/usr/bin/env bash
# The billing bucket refuses destroy and replacement at plan
# (lifecycle.prevent_destroy), before Terraform would destroy its dependents
# first: the policy (and with it the delete deny and the delivery allow),
# versioning (suspended), the public access block and the ownership controls.
#
# Mocked providers cannot plan a replacement or a destroy, so this checks the
# configuration itself: the bucket resource must carry the lifecycle guard.
set -euo pipefail

cd "$(dirname "$0")/.."

python3 -I - main.tf <<'PY'
import re
import sys

source = open(sys.argv[1]).read()
block = re.search(r'^resource "aws_s3_bucket" "this" \{\n(.*?)^\}', source, re.S | re.M)
if block is None:
    sys.exit('main.tf: no resource "aws_s3_bucket" "this"')
if not re.search(r'lifecycle\s*\{[^}]*\bprevent_destroy\s*=\s*true\b', block.group(1)):
    sys.exit('main.tf: aws_s3_bucket.this must set lifecycle { prevent_destroy = true }')
print("ok: aws_s3_bucket.this refuses destroy and replacement")
PY
