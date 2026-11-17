"""The export string built in Lua, read back by tools/check_export.py, and strings the checker must refuse.

Requires: pip install lupa
Run: python tests/test_export.py
"""
import base64
import pathlib
import subprocess
import sys
import tempfile
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "tools"))
from wowsim import Client, expect, report  # noqa: E402
import check_export  # noqa: E402
from test_share import bucket_view, loot_mob, plain  # noqa: E402


def lua_list(table):
    return [table[i] for i in range(1, len(table) + 1)]


def checked(string):
    try:
        return check_export.check(string)
    except check_export.Invalid as error:
        return "rejected: %s" % error


def pack(text, encoding="utf-8"):
    return "DT1:" + base64.b64encode(zlib.compress(text.encode(encoding))).decode("ascii")


def json_view(bucket):
    """Checker bucket -> the shape bucket_view gives for a Lua bucket."""
    return {
        "kills": bucket["kills"], "lootable": bucket["lootable"], "opened": bucket["opened"], "money": bucket["money"],
        "items": {int(k): v for k, v in bucket["items"].items()},
    }


def main():
    alice = Client("Alice")
    ns = alice.ns
    own = ns.db.installId
    alice.stand(1429, 0.31, 0.62)
    for spawn in ("A1", "A2"):
        loot_mob(alice, 1, spawn, [(100, 2), (101, 1)], copper=12)
    loot_mob(alice, 2, "B1", [(100, 1)])
    alice.see(1, "A1", 5)

    expect("export available", ns.CanExport(), True)
    result = ns.BuildExport(False)
    strings = lua_list(result.strings)
    expect("one part", len(strings), 1)
    parsed = checked(strings[0])
    expect("checker accepts the export", isinstance(parsed, dict), True)
    mobs = parsed["sources"][own]["mobs"]
    expect("both mobs exported", sorted(mobs), ["1", "2"])
    expect("counts survive", json_view(mobs["1"]["buckets"]["1"]), bucket_view(ns.db.mobs[1][1]))
    expect("level and name", (mobs["1"]["levels"], mobs["1"]["name"]), ([5, 5], "Test Mob"))
    expect("kill spots", mobs["1"]["cells"], {"1429": {str(k): v for k, v in plain(ns.db.info[1].maps[1429].cells).items()}})
    expect("summary counts", (result.mobs, result.kills, result.sources), (2, 3, 0))

    # After copying, only what changes later goes out.
    ns.MarkExported(result)
    expect("nothing new", len(lua_list(ns.BuildExport(False).strings)), 0)
    expect("nothing changed", ns.ChangedCount(), 0)
    loot_mob(alice, 2, "B2", [(101, 1)])
    parsed = checked(lua_list(ns.BuildExport(False).strings)[0])
    expect("only the changed mob", sorted(parsed["sources"][own]["mobs"]), ["2"])
    expect("everything on request", sorted(checked(lua_list(ns.BuildExport(True).strings)[0])["sources"][own]["mobs"]),
           ["1", "2"])

    # A kill between building and copying stays new.
    pending = ns.BuildExport(False)
    loot_mob(alice, 2, "B3", [(101, 1)])
    ns.MarkExported(pending)
    expect("kill after building still new", ns.ChangedCount(), 1)

    # Counts other players whispered back go out in their own section (answers count only after asking).
    peer = "0123456789abcdef"
    alice.advance(10)
    alice.see(5, "P1", 2)
    alice.fire("CHAT_MSG_ADDON", "DropTables", "D|%s|M5.1.a.a.a.0.0..;I5.1.2s.3.3.1.1;L5.2.3" % peer,
               "WHISPER", "Bob")
    parsed = checked(lua_list(ns.BuildExport(False).strings)[0])
    expect("peer section", parsed["sources"][peer]["mobs"]["5"]["buckets"]["1"]["kills"], 10)
    expect("peer levels", parsed["sources"][peer]["mobs"]["5"]["levels"], [2, 3])

    # A half-received bucket of another player (items counted above its corpses) stays out of the export.
    other = "fedcba9876543210"
    alice.advance(6)
    alice.see(6, "P2", 2)
    alice.fire("CHAT_MSG_ADDON", "DropTables", "D|%s|M6.1.2.2.2.0.0.." % other, "WHISPER", "Bob")
    alice.fire("CHAT_MSG_ADDON", "DropTables", "D|%s|I6.1.2s.3.3.1.1" % other, "WHISPER", "Bob")
    parsed = checked(lua_list(ns.BuildExport(True).strings)[0])
    expect("export with a half bucket still valid", isinstance(parsed, dict), True)
    expect("half bucket left out", isinstance(parsed, dict) and other in parsed["sources"], False)

    # Mob names come in the language of the game client.
    ns.db.names[2] = "Пещерен вълк"
    parsed = checked(lua_list(ns.BuildExport(True).strings)[0])
    expect("name in another language", isinstance(parsed, dict) and parsed["sources"][own]["mobs"]["2"]["name"],
           "Пещерен вълк")

    # A big table is split into parts that each fit and each check out.
    alice.lua.execute("""
        math.randomseed(7)
        for npc = 1000, 4000 do
            local items = {}
            for i = 1, 12 do
                local drops = math.random(1, 900000)
                items[math.random(1, 9000000)] = { drops = drops, qty = drops + math.random(0, 900000),
                    min = math.random(1, 9), max = math.random(10, 99) }
            end
            DropTablesDB.mobs[npc] = { [1] = { kills = 999999, lootable = 999998, opened = 999997, items = items,
                money = { drops = 40, copper = math.random(1, 900000), min = 20, max = 200 } } }
        end
    """)
    big = lua_list(ns.BuildExport(True).strings)
    expect("several parts", len(big) > 1, True)
    expect("every part fits", max(len(s) for s in big) <= 60000, True)
    seen = set()
    for i, string in enumerate(big, 1):
        part = checked(string)
        expect("part %d valid" % i, isinstance(part, dict), True)
        if isinstance(part, dict):
            expect("part %d numbered" % i, (part["part"], part["parts"]), (i, len(big)))
            seen.update(part["sources"][own]["mobs"])
    expect("all mobs across the parts", len(seen), len(list(ns.db.mobs.keys())))

    # Strings the checker refuses.
    good = strings[0]
    header = "DTX|1|%s|0.2.0|1700000000|1/1\n@%s\n" % (own, own)
    bad = {
        "cut short": good[:4 + (len(good) - 4) // 8 * 4],  # whole base64 groups, so only zlib can notice
        "checksum missing": "DT1:" + base64.b64encode(zlib.compress(
            (header + "M1.1.a.a.a.0.0..").encode("ascii"))[:-4]).decode("ascii"),
        "one character changed": good[:40] + ("A" if good[40] != "A" else "B") + good[41:],
        "wrong prefix": "DT2:" + good[4:],
        "spaces inside": good[:20] + " " + good[20:],
        "not base64": "DT1:@@@@",
        "too long": "DT1:" + "A" * 200001,
        "bomb": pack(header + "\n".join(["M1.1.a.a.a.0.0.."] * 200_000)),
        "number too long": pack(header + "M1.1.123456789.a.a.0.0.."),
        "item above opened": pack(header + "M1.1.5.5.5.0.0..;I1.1.2s.6.6.1.1"),
        "lua in place of records": pack(header + "os.execute('rm -rf /')"),
        "records before install": pack("DTX|1|%s|0.2.0|1700000000|1/1\nM1.1.a.a.a.0.0.." % own),
        "bad header": pack("DTX|9|x\n@%s\nM1.1.a.a.a.0.0.." % own),
        "two mobs on a line": pack(header + "M1.1.a.a.a.0.0..;M2.1.a.a.a.0.0.."),
        "not utf-8": pack(header + "N1.Gnöll", "latin-1"),
        "name over 64 bytes": pack(header + "N1." + "ö" * 33),
        "name with escape": pack(header + "N1.|cffff0000x"),
        "empty": pack("DTX|1|%s|0.2.0|1700000000|1/1" % own),
    }
    for label, string in bad.items():
        result = checked(string)
        expect("refuses %s" % label, isinstance(result, str) and result.startswith("rejected"), True)

    # The command line: exit code 0 and a summary, or 1 and the reason.
    with tempfile.TemporaryDirectory() as folder:
        path = pathlib.Path(folder) / "export.txt"
        for string, code in ((good, 0), (bad["cut short"], 1)):
            path.write_text(string, encoding="utf-8")
            run = subprocess.run([sys.executable, str(ROOT / "tools" / "check_export.py"), str(path)],
                                 capture_output=True, text=True)
            expect("exit code %d" % code, run.returncode, code)

    report("export")


if __name__ == "__main__":
    main()
