#!/usr/bin/env python3
"""A fake `aws` for cost-sync's tests: a local directory stands in for S3.

  aws [--region R] s3api list-objects-v2 --bucket B --prefix P --output json
  aws [--region R] s3 cp s3://B/KEY DEST [--only-show-errors]

FAKE_S3_ROOT/<bucket>/<key> is an object. Its ETag is the quoted md5 of its
bytes (as S3's for a single-part put), LastModified its file mtime. A missing
key fails as S3 does (404). FAKE_AWS_FAIL=1 fails every call.
"""

import hashlib
import json
import os
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    sys.exit(1)


def option(args: list, name: str) -> str:
    return args[args.index(name) + 1]


def main(argv: list) -> None:
    if os.environ.get("FAKE_AWS_FAIL") == "1":
        fail("Could not connect to the endpoint URL")
    args = list(argv)
    while args and args[0] in ("--region", "--profile"):
        args = args[2:]
    root = Path(os.environ["FAKE_S3_ROOT"])
    if args[:2] == ["s3api", "list-objects-v2"]:
        bucket, prefix = option(args, "--bucket"), option(args, "--prefix")
        base = root / bucket
        contents = []
        for path in sorted(base.rglob("*")):
            key = str(path.relative_to(base))
            if path.is_file() and key.startswith(prefix):
                stamp = datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).isoformat()
                contents.append({"Key": key, "ETag": '"%s"' % hashlib.md5(path.read_bytes()).hexdigest(), "LastModified": stamp})
        print(json.dumps({"Contents": contents} if contents else {}))
        return
    if args[:2] == ["s3", "cp"]:
        source, dest = args[2], args[3]
        bucket, _, key = source[len("s3://"):].partition("/")
        path = root / bucket / key
        if not path.is_file():
            fail("fatal error: An error occurred (404) when calling the HeadObject operation: Not Found")
        if dest == "-":
            sys.stdout.buffer.write(path.read_bytes())
        else:
            shutil.copyfile(path, dest)
        return
    fail(f"fake aws: unsupported call {argv}")


if __name__ == "__main__":
    main(sys.argv[1:])
