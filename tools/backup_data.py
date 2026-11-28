"""Uploads the data folder as it is in the last commit (git archive HEAD data) to a Cloudflare R2 bucket, when the build
changed something there or in the DropTables_Data addon, so the inputs from before a commit can come back even if the
repository is lost. Then it deletes the backups past what is kept: the newest KEEP_LATEST, and the newest of each day
for KEEP_DAYS days. Files in the bucket with other names are left alone.

Needs R2_ACCOUNT_ID, R2_BUCKET, R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY in the environment; without them it says so
and does nothing. With them, a failed upload ends it with an error, so the workflow doesn't commit. It talks to R2 with
the AWS CLI, which the Ubuntu runners of GitHub Actions have.

Usage:
    python tools/backup_data.py [--root DIR]
"""
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
KEEP_LATEST = 10
KEEP_DAYS = 30
NAME = re.compile(r"^data/(\d{4}-\d{2}-\d{2})T(\d{6})Z-[0-9a-f]+\.tar\.gz$")
NEEDED = ("R2_ACCOUNT_ID", "R2_BUCKET", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY")


def backup_key(now, commit):
    return "data/%sZ-%s.tar.gz" % (time.strftime("%Y-%m-%dT%H%M%S", time.gmtime(now)), commit[:12])


def kept(keys, now):
    """The backups among keys to keep."""
    dated = sorted(((m.group(1) + m.group(2), key) for key in keys for m in [NAME.match(key)] if m), reverse=True)
    keep = {key for _, key in dated[:KEEP_LATEST]}
    oldest = time.strftime("%Y-%m-%d", time.gmtime(now - (KEEP_DAYS - 1) * 86400))
    days = set()
    for stamp, key in dated:
        day = stamp[:10]
        if day >= oldest and day not in days:
            days.add(day)
            keep.add(key)
    return keep


def to_delete(keys, now):
    return sorted(key for key in keys if NAME.match(key) and key not in kept(keys, now))


def main(argv, env=None, run=subprocess.run, now=None):
    sys.stdout.reconfigure(encoding="utf-8")
    env = os.environ if env is None else env
    root = pathlib.Path(argv[argv.index("--root") + 1]) if "--root" in argv else ROOT
    missing = [name for name in NEEDED if not env.get(name)]
    if missing:
        print("::warning::No backup to R2, %s not set." % ", ".join(missing))
        return 0

    def git(*args):
        return run(["git", *args], cwd=root, check=True, capture_output=True, text=True).stdout

    if not git("status", "--porcelain", "--", "data", "DropTables_Data").strip():
        print("Nothing changed, so no backup.")
        return 0
    aws_env = dict(env, AWS_ACCESS_KEY_ID=env["R2_ACCESS_KEY_ID"], AWS_SECRET_ACCESS_KEY=env["R2_SECRET_ACCESS_KEY"],
                   AWS_DEFAULT_REGION="auto", AWS_REQUEST_CHECKSUM_CALCULATION="when_required",
                   AWS_RESPONSE_CHECKSUM_VALIDATION="when_required")
    bucket = env["R2_BUCKET"]
    endpoint = "https://%s.r2.cloudflarestorage.com" % env["R2_ACCOUNT_ID"]

    def s3api(*args):
        out = run(["aws", "s3api", *args, "--bucket", bucket, "--endpoint-url", endpoint, "--output", "json"],
                  env=aws_env, check=True, capture_output=True, text=True).stdout
        return json.loads(out) if out.strip() else None

    now = time.time() if now is None else now
    key = backup_key(now, git("rev-parse", "HEAD").strip())
    with tempfile.TemporaryDirectory() as folder:
        archive = pathlib.Path(folder) / "data.tar.gz"
        git("archive", "--format=tar.gz", "-o", str(archive), "HEAD", "data")
        size = archive.stat().st_size
        s3api("put-object", "--key", key, "--body", str(archive))
    stored = s3api("head-object", "--key", key)
    if not stored or stored.get("ContentLength") != size:
        print("The backup %s in R2 doesn't have the %d bytes that were sent." % (key, size))
        return 1
    print("Backed up the data folder of %s to R2 as %s (%d bytes)." % (git("rev-parse", "--short", "HEAD").strip(),
                                                                       key, size))
    keys = s3api("list-objects-v2", "--prefix", "data/", "--query", "Contents[].Key") or []
    for old in to_delete(keys, now):
        s3api("delete-object", "--key", old)
        print("Deleted the old backup " + old)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
