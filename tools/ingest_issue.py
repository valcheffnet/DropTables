"""Takes the export strings out of GitHub issues and saves the valid ones as submissions.

Issues are untrusted, so they're only ever read from a JSON file (never from a shell line), every string goes through
tools/check_export.py, and nothing in them gets executed.

Usage:
    python tools/ingest_issue.py ISSUES_JSON --replies DIR [--root DIR]
ISSUES_JSON is a list of issues as `gh issue list --json number,body,author,labels,createdAt` gives it. Writes
data/submissions/<issue>-<n>.json for each new string, DIR/<issue>.md with the reply for each issue, DIR/outcomes.txt
with one "<issue> <accepted|rejected|duplicate>" line per issue and DIR/message.txt with the commit message.
"""
import datetime
import hashlib
import json
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import check_export  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
MAX_BODY = 1_000_000
MAX_STRINGS = 10   # parts in one issue
DAILY_LIMIT = 20   # accepted strings per submitter per UTC day
STRING_RE = re.compile(r"DT1:[A-Za-z0-9+/]+={0,2}")
SHARE_PAGE = "https://droptables-relay.valcheffnet.workers.dev"


def received_time(issue):
    created = issue.get("created_at") or issue.get("createdAt")
    if not created:
        return 0
    return int(datetime.datetime.fromisoformat(created.replace("Z", "+00:00")).timestamp())


def labels(issue):
    return {label["name"] if isinstance(label, dict) else str(label) for label in issue.get("labels") or []}


def author(issue):
    user = issue.get("user") or issue.get("author") or {}
    return str(user.get("login") or "unknown")


def existing(folder):
    subs = []
    for path in folder.glob("*.json"):
        subs.append(json.loads(path.read_text(encoding="utf-8")))
    return subs


def count(n, word):
    return "%d %s%s" % (n, word, "" if n == 1 else "s")


def day(timestamp):
    return datetime.datetime.fromtimestamp(timestamp, datetime.timezone.utc).date()


def ingest(issue, root):
    """Returns (outcome, reply text)."""
    number = int(issue["number"])
    body = (issue.get("body") or "")[:MAX_BODY]
    strings = STRING_RE.findall(body)
    if not strings:
        return "rejected", ("I couldn't find any export text in this issue. In game, type `/dt export`, press Select "
                            "and then Ctrl+C, and paste the text on the share page at " + SHARE_PAGE + ". It starts "
                            "with `DT1:`.")
    if len(strings) > MAX_STRINGS:
        return "rejected", "This issue has %d export texts. Please send at most %d in one issue." % (
            len(strings), MAX_STRINGS)
    folder = root / "data" / "submissions"
    folder.mkdir(parents=True, exist_ok=True)
    known = existing(folder)
    hashes = {s["sha256"] for s in known}
    received = received_time(issue)
    relay = "relay" in labels(issue)
    new, problems, duplicates = [], [], 0
    for index, string in enumerate(strings, 1):
        digest = hashlib.sha256(string.encode("ascii")).hexdigest()
        if digest in hashes:
            duplicates += 1
            continue
        try:
            result = check_export.check(string)
        except check_export.Invalid as error:
            problems.append("part %d: %s" % (index, error) if len(strings) > 1 else str(error))
            continue
        hashes.add(digest)
        submitter = "relay:" + result["exporter"] if relay else author(issue)
        new.append({"issue": number, "index": index, "submitter": submitter, "received": received,
                    "sha256": digest, "string": string, "result": result})
    if new:
        submitter = new[0]["submitter"]
        today = sum(1 for s in known if s["submitter"] == submitter and day(s["received"]) == day(received))
        if today + len(new) > DAILY_LIMIT:
            return "rejected", "You sent more than %d exports today. Please send the rest tomorrow." % DAILY_LIMIT
    for sub in new:
        path = folder / ("%d-%d.json" % (sub["issue"], sub["index"]))
        path.write_text(json.dumps(sub, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")
    if not new:
        if problems:
            return "rejected", "The export text couldn't be used: %s." % "; ".join(problems)
        return "duplicate", "This export text was sent before, so there was nothing new to add."
    installs = {o for s in new for o in s["result"]["sources"]}
    mobs = {npc for s in new for source in s["result"]["sources"].values() for npc in source["mobs"]}
    kills = sum(b["kills"] for s in new for source in s["result"]["sources"].values()
                for mob in source["mobs"].values() for b in mob["buckets"].values())
    reply = ("Thanks! Your counts are in the shared database now (%s, %s, %s), and everyone gets them with the next "
             "Drop Tables release." % (count(len(installs), "install"), count(len(mobs), "mob"), count(kills, "kill")))
    if problems:
        reply += " Part of it couldn't be used: %s." % "; ".join(problems)
    if duplicates:
        reply += " %s had been sent before." % count(duplicates, "part")
    return "accepted", reply


def main(argv):
    root = pathlib.Path(argv[argv.index("--root") + 1]) if "--root" in argv else ROOT
    replies = pathlib.Path(argv[argv.index("--replies") + 1])
    replies.mkdir(parents=True, exist_ok=True)
    issues = json.loads(pathlib.Path(argv[0]).read_text(encoding="utf-8"))
    outcomes, accepted = [], []
    for issue in sorted(issues, key=lambda i: int(i["number"])):
        number = int(issue["number"])
        outcome, reply = ingest(issue, root)
        (replies / ("%d.md" % number)).write_text(reply + "\n", encoding="utf-8")
        outcomes.append("%d %s" % (number, outcome))
        if outcome == "accepted":
            accepted.append("#%d" % number)
    (replies / "outcomes.txt").write_text("".join(line + "\n" for line in outcomes), encoding="utf-8")
    message = ("Add shared drop counts from %s %s" % ("issue" if len(accepted) == 1 else "issues", ", ".join(accepted))
               if accepted else "Rebuild the shared drop database")
    (replies / "message.txt").write_text(message + "\n", encoding="utf-8")
    print("\n".join(outcomes) or "no issues")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
