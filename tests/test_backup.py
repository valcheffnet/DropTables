"""Backups of the data folder to R2 (tools/backup_data.py): which ones are kept, and a run against a stand-in for the
AWS CLI in a throwaway git repository.

Requires: pip install lupa
Run: python tests/test_backup.py
"""
import calendar
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "tools"))
from wowsim import expect, report  # noqa: E402
import backup_data  # noqa: E402

NOW = calendar.timegm((2026, 11, 28, 12, 0, 0))
HOUR = 3600
ENV = {"R2_ACCOUNT_ID": "acc", "R2_BUCKET": "bucket", "R2_ACCESS_KEY_ID": "id", "R2_SECRET_ACCESS_KEY": "secret"}


def key_at(hours_ago, commit="abc123"):
    return backup_data.backup_key(NOW - hours_ago * HOUR, commit)


def keeping():
    # Five backups a day for 40 days, at 20:00, 16:00, 12:00, 08:00 and 04:00, and it is 23:30 now.
    midnight = calendar.timegm((2026, 11, 28, 0, 0, 0))
    now = midnight + 23 * HOUR + 1800

    def at(day, hour):
        return backup_data.backup_key(midnight - day * 24 * HOUR + hour * HOUR, "abc123")

    keys = [at(day, hour) for day in range(40) for hour in (20, 16, 12, 8, 4)]
    keep = backup_data.kept(keys + ["data/notes.txt"], now)
    expect("the newest ten are kept", all(k in keep for k in keys[:10]), True)
    days = sorted({k[5:15] for k in keep})
    expect("one a day for 30 days", (len(days), days[0], days[-1]), (30, "2026-10-30", "2026-11-28"))
    expect("ten plus the newest of each older day", len(keep), 10 + 28)
    expect("the newest of a day is the one kept", at(5, 20) in keep, True)
    expect("an older one of that day is not", at(5, 16) in keep, False)
    gone = backup_data.to_delete(keys + ["data/notes.txt", "other/x.tar.gz"], now)
    expect("files with other names are never deleted", [k for k in gone if not k.endswith("Z-abc123.tar.gz")], [])
    expect("everything else goes", len(gone), 200 - 38)
    expect("a few backups are all kept", backup_data.to_delete([key_at(1), key_at(30 * 24)], NOW), [])


class FakeAws:
    """Runs git for real and answers the aws calls the way R2 would."""

    def __init__(self, listed, short=False):
        self.listed, self.short, self.calls, self.sizes = listed, short, [], {}

    def __call__(self, command, **kwargs):
        if command[0] == "git":
            return subprocess.run(command, **kwargs)
        self.calls.append(command[2:command.index("--bucket")])
        action, out = command[2], ""
        arg = dict(zip(command[3::2], command[4::2]))
        if action == "put-object":
            self.sizes[arg["--key"]] = pathlib.Path(arg["--body"]).stat().st_size - (1 if self.short else 0)
            self.listed.append(arg["--key"])
        elif action == "head-object":
            out = '{"ContentLength": %d}' % self.sizes[arg["--key"]]
        elif action == "list-objects-v2":
            out = "[%s]" % ", ".join('"%s"' % k for k in self.listed)
        return subprocess.CompletedProcess(command, 0, out, "")


def runs(root):
    def git(*args):
        subprocess.run(["git", *args], cwd=root, check=True, capture_output=True)

    git("init", "-q")
    (root / "data").mkdir()
    (root / "data" / "shared.json").write_text("{}\n", encoding="utf-8")
    git("add", "data")
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "first")
    args = ["--root", str(root)]

    aws = FakeAws([])
    expect("without the secrets it does nothing", backup_data.main(args, env={}, run=aws), 0)
    expect("and calls nothing", aws.calls, [])
    expect("nothing changed, no backup", backup_data.main(args, env=ENV, run=aws, now=NOW), 0)
    expect("and no upload", aws.calls, [])

    (root / "data" / "shared.json").write_text('{"mobs": {}}\n', encoding="utf-8")
    old = [key_at(1 + day * 24) for day in range(35)]
    aws = FakeAws(list(old))
    expect("a changed build is backed up", backup_data.main(args, env=ENV, run=aws, now=NOW), 0)
    put = [c for c in aws.calls if c[0] == "put-object"]
    expect("one upload", len(put), 1)
    expect("its name", aws.listed[-1].startswith("data/2026-11-28T120000Z-"), True)
    deleted = [c[c.index("--key") + 1] for c in aws.calls if c[0] == "delete-object"]
    expect("the backups past 30 days are deleted", deleted, sorted(old[30:]))
    expect("the archive holds the committed data", sorted(aws.sizes.values())[0] > 0, True)

    aws = FakeAws([], short=True)
    expect("a short upload is an error", backup_data.main(args, env=ENV, run=aws, now=NOW), 1)
    expect("and nothing is deleted after it", [c[0] for c in aws.calls], ["put-object", "head-object"])


def main():
    keeping()
    with tempfile.TemporaryDirectory() as folder:
        runs(pathlib.Path(folder))
    report("backup")


if __name__ == "__main__":
    main()
