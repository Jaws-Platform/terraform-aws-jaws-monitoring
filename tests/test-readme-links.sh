#!/usr/bin/env bash
# The Terraform Registry shows the root, submodule and example READMEs but does
# not resolve relative links (see CONTRIBUTING.md), so every link in them must
# be absolute or an in-page anchor.
set -euo pipefail

cd "$(dirname "$0")/.."

python3 -I - README.md modules/*/README.md examples/*/README.md <<'PY'
import re
import sys

bad = []
for path in sys.argv[1:]:
    for number, line in enumerate(open(path), 1):
        for target in re.findall(r'\]\(([^)\s]+)\)', line):
            if not re.match(r'(https?://|mailto:|#)', target):
                bad.append(f"{path}:{number}: relative link ({target})")
if bad:
    sys.exit("\n".join(bad))
print(f"ok: {len(sys.argv) - 1} READMEs use absolute links")
PY
