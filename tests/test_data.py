"""The shared database: exports sent as GitHub issues, merged by tools/build_data.py, loaded back as Data.lua.

Requires: pip install lupa
Run: python tests/test_data.py
"""
import json
import pathlib
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "tools"))
from wowsim import Client, expect, report  # noqa: E402
from test_share import Net, loot_mob  # noqa: E402
import build_data  # noqa: E402
import ingest_issue  # noqa: E402

DAY = "2026-11-18T10:00:00Z"


def issue(number, body, login="alice-gh", labels=(), created=DAY):
    return {"number": number, "body": body, "user": {"login": login}, "labels": [{"name": n} for n in labels],
            "created_at": created}


def form_body(*strings):
    return "### Export text\n\n```text\n%s\n```\n" % "\n".join(strings)


def export_string(client):
    strings = client.ns.BuildExport().strings
    return strings[1]


def shared_lua(root):
    return build_data.lua_file(build_data.build(build_data.load_submissions(root)))


# --- synthetic submissions for the merge rules ------------------------------------------------------------------

def bucket(kills, lootable, opened, items=None, money=0):
    return {"kills": kills, "lootable": lootable, "opened": opened,
            "money": {"drops": money, "copper": money * 10, "min": 10 if money else None, "max": 10 if money else None},
            "items": {str(i): {"drops": d, "qty": d, "min": 1, "max": 1} for i, d in (items or {}).items()}}


def mob(buckets, name="Wolf", levels=(5, 6), maps=None):
    return {"buckets": {str(b): data for b, data in buckets.items()}, "levels": list(levels), "maps": maps or {"12": 1},
            "cells": {}, "name": name}


def submission(number, exporter, sources, submitter=None):
    """sources: origin -> {npc: mob}."""
    return {"issue": number, "index": 1, "submitter": submitter or "user-" + exporter, "received": 1000 + number,
            "sha256": "%064d" % number, "string": "",
            "result": {"exporter": exporter, "version": "0.3.0", "time": 1, "part": 1, "parts": 1,
                       "sources": {o: {"mobs": {str(npc): m for npc, m in mobs.items()}} for o, mobs in sources.items()}}}


def origin(n):
    return "%016x" % (0xa000000000000000 + n)


def merge_rules():
    a, b, c, d = origin(1), origin(2), origin(3), origin(4)
    own = submission(1, a, {a: {7: mob({1: bucket(50, 50, 50, {100: 10})})}})
    relayed_b = submission(2, b, {a: {7: mob({1: bucket(80, 80, 80, {100: 16})})}})
    db = build_data.build([own, relayed_b])
    expect("the install's own export beats one bigger relayed copy", db["mobs"]["7"]["from"], {a: 50})
    relayed_c = submission(3, c, {a: {7: mob({1: bucket(90, 90, 90, {100: 18})})}})
    db = build_data.build([own, relayed_b, relayed_c])
    expect("two exporters with more kills win, at the smaller of the two", db["mobs"]["7"]["from"], {a: 80})
    db = build_data.build([relayed_b])
    expect("a relayed copy counts when the install never exported", db["mobs"]["7"]["from"], {a: 80})
    newer = submission(4, a, {a: {7: mob({1: bucket(60, 60, 60, {100: 12})})}})
    db = build_data.build([own, newer])
    expect("the latest own export (most kills) wins", db["mobs"]["7"]["buckets"]["1"]["kills"], 60)
    opened_later = submission(5, a, {a: {7: mob({1: bucket(60, 60, 50, {100: 12})})}})
    for order in ([newer, opened_later], [opened_later, newer]):
        db = build_data.build([own] + order)
        expect("same kills: the one with more corpses opened", db["mobs"]["7"]["buckets"]["1"]["opened"], 60)
    same = submission(6, a, {a: {7: mob({1: bucket(60, 60, 60, {100: 13})})}})
    for order in ([newer, same], [same, newer]):
        db = build_data.build(order)
        expect("a full tie: the latest issue", db["mobs"]["7"]["buckets"]["1"]["items"]["100"]["drops"], 13)

    # Three honest installs and one claiming hundreds of empty corpses.
    honest = [submission(10 + i, origin(10 + i), {origin(10 + i): {8: mob({1: bucket(100, 90, 90, {100: 45})})}})
              for i in range(3)]
    liar = submission(20, d, {d: {8: mob({1: bucket(1000, 10, 10, {100: 5})})}})
    db = build_data.build(honest + [liar])
    expect("the empty-kill liar is left out", sorted(db["mobs"]["8"]["from"]), sorted(origin(10 + i) for i in range(3)))
    expect("kills of the honest three", db["mobs"]["8"]["buckets"]["1"]["kills"], 300)
    item_liar = submission(21, d, {d: {8: mob({1: bucket(100, 90, 90, {100: 0, 101: 1})})}})
    item_liar["result"]["sources"][d]["mobs"]["8"]["buckets"]["1"]["items"].pop("100")
    db = build_data.build(honest + [item_liar])
    expect("an install that never sees a 50% drop is left out", d in db["mobs"]["8"]["from"], False)
    big = [submission(30, origin(30), {origin(30): {9: mob({1: bucket(3000, 3000, 3000, {100: 300})})}})]
    db = build_data.build(big)
    expect("one install counts at most 300 kills", db["mobs"]["9"]["buckets"]["1"]["kills"], 300)
    expect("its drops scale with it", db["mobs"]["9"]["buckets"]["1"]["items"]["100"]["drops"], 30)

    # One submitter relaying 60 install ids nobody else ever sent: 50 count.
    fakes = {origin(100 + i): {10 + i: mob({1: bucket(5, 5, 5)})} for i in range(60)}
    db = build_data.build([submission(40, origin(99), fakes, submitter="spammer")])
    expect("unconfirmed installs per submitter are capped", len(db["mobs"]), build_data.UNCONFIRMED_CAP)

    # Same input, same output.
    subs = honest + [liar, own, relayed_b]
    first = build_data.lua_file(build_data.build(subs))
    expect("the build is the same every time", build_data.lua_file(build_data.build(list(reversed(subs)))), first)

    # An install id made only of digits stays text in Lua.
    digits = "1234567890123456"
    lua = build_data.lua_file(build_data.build([submission(50, digits, {digits: {11: mob({1: bucket(3, 3, 3)})}})]))
    client = Client("Digits", data=lua)
    expect("digit install id is a string key", client.ns.shared[11]["from"][digits], 3)

    # Many mobs are written in chunks and all load.
    many = {origin(500): {1000 + i: mob({1: bucket(4, 4, 3, {100 + i % 50: 1})}, name="Mob %d" % i) for i in range(3000)}}
    lua = build_data.lua_file(build_data.build([submission(60, origin(500), many)]))
    expect("chunks of 500 mobs", lua.count("ns.AddSharedData(function()"), 6)
    client = Client("Many", data=lua)
    expect("all mobs loaded", sum(1 for _ in client.ns.shared.keys()), 3000)


# --- issues, in-game export and the shared data in the addon ----------------------------------------------------

def issues_and_game(root):
    alice = Client("Alice")
    alice.stand(12, 0.3, 0.3)
    for i in range(10):
        loot_mob(alice, 1, "A%d" % i, [(100, 1)] if i % 2 == 0 else [(101, 2)])
    alice.see(1, "A0", 5)
    alice_id = alice.ns.db.installId
    string = export_string(alice)

    outcome, reply = ingest_issue.ingest(issue(1, form_body(string)), root)
    expect("an export is accepted", outcome, "accepted")
    expect("the reply counts what came in", "1 install, 1 mob, 10 kills" in reply, True)
    expect("the same text again adds nothing", ingest_issue.ingest(issue(2, form_body(string)), root)[0], "duplicate")
    broken = string[:-12] + "AAAAAAAAAAAA"
    outcome, reply = ingest_issue.ingest(issue(3, form_body(broken)), root)
    expect("a damaged text is refused with the checker's reason", (outcome, "damaged" in reply or "cut" in reply),
           ("rejected", True))
    expect("an issue without a text is refused", ingest_issue.ingest(issue(4, "hello"), root)[0], "rejected")
    expect("only valid texts were saved", sorted(p.name for p in (root / "data" / "submissions").glob("*.json")),
           ["1-1.json"])
    erin = Client("Erin")
    loot_mob(erin, 3, "E1", [(100, 1)])
    outcome, _ = ingest_issue.ingest(issue(5, form_body(export_string(erin)), login="share[bot]",
                                           labels=("share", "relay")), root)
    saved = build_data.load_submissions(root)[-1]
    expect("a page issue is filed under its install", (outcome, saved["submitter"]),
           ("accepted", "relay:" + erin.ns.db.installId))

    lua = shared_lua(root)
    carol = Client("Carol", data=lua)
    stats = carol.ns.GetStats(1, "all")
    expect("a mob carol never met has chances", (stats.kills, stats.sharedKills, stats.ownKills), (10, 10, 0))
    rates = {e.itemId: round(e.rate, 2) for e in stats.list.values() if e.itemId}
    expect("shared chances", rates, {100: 0.5, 101: 0.5})
    expect("the shared mob is known", carol.ns.KnownNpcs()[1], True)
    expect("its name and level come along", (carol.ns.MobName(1), carol.ns.MobInfo(1).minLevel), ("Test Mob", 5))
    expect("the loot finder lists it", sorted(d.npc for d in carol.ns.FindDroppers(100).values()), [1, 3])
    carol.ns.settings.onlyMine = True
    carol.fire("DT_SETTINGS_CHANGED")
    expect("only mine hides the shared data", carol.ns.GetStats(1, "all"), None)
    carol.ns.settings.onlyMine = False
    carol.fire("DT_SETTINGS_CHANGED")

    # Alice's own kills are in the database already; they count once, and new kills count on top.
    alice2 = Client("Alice", saved=_saved_db(alice), data=lua)
    expect("same install", alice2.ns.db.installId, alice_id)
    stats = alice2.ns.GetStats(1, "all")
    expect("own kills in the database count once", (stats.kills, stats.ownKills), (10, 10))
    for i in range(10, 14):
        loot_mob(alice2, 1, "A%d" % i, [(100, 1)])
    stats = alice2.ns.GetStats(1, "all")
    expect("new kills after the export count", (stats.kills, stats.ownKills), (14, 14))
    rates = {e.itemId: round(e.rate, 4) for e in stats.list.values() if e.itemId}
    # The new part is alice's counts times 4/14: what changed since the export is not kept, only how much.
    expect("the new part moves the chance", rates[100], round((5 + 9 * 4 / 14) / 14, 4))

    # Counts of alice that bob got over the channel are in the database too.
    bob = Client("Bob", data=lua)
    bob.lua.execute("""
        local alice = "%s"
        DropTablesDB.peers[1] = { [alice] = { t = 1, maps = {}, buckets = { [1] = { kills = 10, lootable = 10,
            opened = 10, items = { [100] = { drops = 5, qty = 5 }, [101] = { drops = 5, qty = 10 } },
            money = { drops = 0, copper = 0 } } } } }
    """ % alice_id)
    bob.fire("DT_DATA_CHANGED", 1)
    stats = bob.ns.GetStats(1, "all")
    expect("another player's counts already in the database count once", (stats.kills, stats.peerKills), (10, 0))
    export = bob.ns.BuildExport()
    expect("neither the database nor counts it holds are exported", len(list(export.strings.values())), 0)

    # A mob the database knows well is asked about once a day, like one the player holds 100 corpses of.
    many = {origin(700): {2: mob({1: bucket(150, 150, 150, {100: 30})})}}
    lua = build_data.lua_file(build_data.build([submission(70, origin(700), many)]))
    dave = Client("Dave", data=lua)
    net = Net(dave)
    net.run(10)
    start = len(net.log)
    dave.see(2, "D1", 5)
    net.run(10)
    expect("one daily question about a mob the database knows well", len(net.sent("Dave", "Q|", start)), 1)
    start = len(net.log)
    net.run(600)
    dave.see(2, "D2", 5)
    net.run(10)
    expect("not again the same day", net.sent("Dave", "Q|", start), [])


def pruning(root):
    """A player who sends everything each time leaves only the latest submission; the database stays the same."""
    a, b = origin(900), origin(901)
    first = submission(1, a, {a: {7: mob({1: bucket(50, 50, 40, {100: 10})})}, b: {8: mob({1: bucket(5, 5, 5)})}})
    second = submission(2, a, {a: {7: mob({1: bucket(60, 60, 40, {100: 12})}), 9: mob({1: bucket(3, 3, 3)})},
                               b: {8: mob({1: bucket(5, 5, 5)})}})
    fewer_opened = submission(3, a, {a: {7: mob({1: bucket(70, 70, 30, {100: 12})})}, b: {8: mob({1: bucket(5, 5, 5)})}})
    partial = submission(4, a, {a: {7: mob({1: bucket(80, 80, 80, {100: 16})})}})
    other = submission(5, b, {a: {7: mob({1: bucket(90, 90, 90, {100: 18})})}, b: {8: mob({1: bucket(6, 6, 6)})}})
    old = [x["issue"] for x in build_data.superseded([first, second, fewer_opened, partial, other])]
    expect("only the fully covered submission goes", old, [1])
    expect("more kills but fewer opened corpses covers nothing", build_data.superseded([first, fewer_opened]), [])
    folder = root / "data" / "submissions"
    folder.mkdir(parents=True)
    for sub in (first, second, fewer_opened, partial, other):
        (folder / ("%d-1.json" % sub["issue"])).write_text(json.dumps(sub), encoding="utf-8")
    before = build_data.lua_file(build_data.build(build_data.load_submissions(root)))
    build_data.main(["--root", str(root)])
    expect("its file is deleted", sorted(p.name for p in folder.glob("*.json")),
           ["2-1.json", "3-1.json", "4-1.json", "5-1.json"])
    after = (root / "DropTables" / "Data.lua").read_text(encoding="utf-8")
    expect("the database does not change", after, before)


def shared_is_trusted():
    """Another install claiming hundreds of empty corpses is left out, never the shared database."""
    lua = build_data.lua_file(build_data.build([submission(80, origin(800), {origin(800): {4: mob({1: bucket(
        100, 100, 100, {100: 50})})}})]))
    frank = Client("Frank", data=lua)
    frank.lua.execute("""
        DropTablesDB.peers[4] = { liar = { t = 1, maps = {}, buckets = { [1] = { kills = 300, lootable = 0,
            opened = 0, items = {}, money = { drops = 0, copper = 0 } } } } }
    """)
    frank.fire("DT_DATA_CHANGED", 4)
    stats = frank.ns.GetStats(4, "all")
    expect("the liar goes, the database stays", (stats.kills, stats.sharedKills), (100, 100))


def _saved_db(client):
    """Lua code that gives a new client the same saved variables."""
    dump = client.lua.execute("""
        local function dump(v)
            if type(v) == "table" then
                local parts = {}
                for k, x in pairs(v) do
                    local key = type(k) == "number" and ("[" .. k .. "]") or ("[" .. string.format("%q", k) .. "]")
                    table.insert(parts, key .. "=" .. dump(x))
                end
                return "{" .. table.concat(parts, ",") .. "}"
            elseif type(v) == "string" then
                return string.format("%q", v)
            end
            return tostring(v)
        end
        return dump
    """)
    return "DropTablesDB = " + dump(client.ns.db)


def issue_list(root):
    """The workflow hands over every open share issue at once, as gh issue list gives them."""
    gina = Client("Gina")
    loot_mob(gina, 6, "G1", [(100, 1)])
    issues = [
        {"number": 9, "body": "no text", "author": {"login": "x"}, "labels": [], "createdAt": DAY},
        {"number": 8, "body": form_body(export_string(gina)), "author": {"login": "gina-gh"},
         "labels": [{"name": "share"}], "createdAt": DAY},
    ]
    listing = root / "issues.json"
    listing.write_text(json.dumps(issues), encoding="utf-8")
    replies = root / "replies"
    ingest_issue.main([str(listing), "--replies", str(replies), "--root", str(root)])
    expect("one outcome per issue, in order", (replies / "outcomes.txt").read_text().splitlines(),
           ["8 accepted", "9 rejected"])
    expect("a reply file per issue", sorted(p.name for p in replies.glob("*.md")), ["8.md", "9.md"])
    expect("commit message names the merged issue", (replies / "message.txt").read_text().strip(),
           "Add shared drop counts from issue #8")


def daily_limit(root):
    for i in range(ingest_issue.DAILY_LIMIT):
        sub = Client("Spam%d" % i)
        loot_mob(sub, 5, "S", [(100, 1)])
        expect_ok = ingest_issue.ingest(issue(100 + i, form_body(export_string(sub)), login="busy"), root)[0]
        if expect_ok != "accepted":
            expect("accepted under the daily limit", expect_ok, "accepted")
    sub = Client("SpamLast")
    loot_mob(sub, 5, "S", [(100, 1)])
    outcome, reply = ingest_issue.ingest(issue(200, form_body(export_string(sub)), login="busy"), root)
    expect("past the daily limit", outcome, "rejected")


def main():
    merge_rules()
    shared_is_trusted()
    with tempfile.TemporaryDirectory() as folder:
        issues_and_game(pathlib.Path(folder))
    with tempfile.TemporaryDirectory() as folder:
        daily_limit(pathlib.Path(folder))
    with tempfile.TemporaryDirectory() as folder:
        issue_list(pathlib.Path(folder))
    with tempfile.TemporaryDirectory() as folder:
        pruning(pathlib.Path(folder))
    report("shared data")


if __name__ == "__main__":
    main()
