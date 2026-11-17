"""Players asking on a simulated hidden channel and whispering drop counts back.

Requires: pip install lupa
Run: python tests/test_share.py
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from wowsim import Client, expect, report  # noqa: E402


def plain(value):
    """Lua table -> Python dict, recursively."""
    if hasattr(value, "items") and callable(value.items):
        return {k: plain(v) for k, v in value.items()}
    return value


class Net:
    """Channel messages reach every client, the sender included; whispers reach the named client."""

    def __init__(self, *clients):
        self.clients = {c.name: c for c in clients}
        self.log = []

    def add(self, *clients):
        for client in clients:
            self.clients[client.name] = client

    def pump(self):
        moved = True
        while moved:
            moved = False
            for sender in list(self.clients.values()):
                for message in sender.take_outbox():
                    prefix, text, chat_type, target = (list(message) + [None])[:4]  # group sends have no target
                    moved = True
                    self.log.append((sender.name, text, chat_type, target, sender.g.now))
                    if chat_type in ("PARTY", "RAID", "INSTANCE_CHAT"):
                        for receiver in self.clients.values():
                            if receiver is sender or sender.name in list(receiver.g.groupMembers.values()):
                                receiver.fire("CHAT_MSG_ADDON", prefix, text, chat_type, sender.name)
                    elif chat_type == "CHANNEL":
                        for receiver in self.clients.values():
                            receiver.fire("CHAT_MSG_ADDON", prefix, text, "CHANNEL", sender.name)
                    elif chat_type == "WHISPER" and target in self.clients:
                        self.clients[target].fire("CHAT_MSG_ADDON", prefix, text, "WHISPER", sender.name)

    def run(self, seconds):
        for _ in range(seconds):
            for client in self.clients.values():
                client.advance(1)
            self.pump()

    def sent(self, name=None, kind=None, start=0):
        return [m for m in self.log[start:] if (name is None or m[0] == name) and (kind is None or m[1].startswith(kind))]


def loot_mob(client, npc, spawn, items, copper=None):
    guid = client.kill(npc, spawn, True)
    client.advance(5)
    slots = [{"type": 1, "item": item, "name": "Item %d" % item, "qty": qty, "sources": [guid, qty]}
             for item, qty in items]
    if copper:
        slots.append({"type": 2, "name": "Copper", "qty": 0, "sources": [guid, copper]})
    client.loot(slots)


def bucket_view(data):
    data = plain(data)
    return {
        "kills": data["kills"], "lootable": data["lootable"], "opened": data["opened"],
        "money": {k: data["money"].get(k) for k in ("drops", "copper", "min", "max")},
        "items": {k: {f: v.get(f) for f in ("drops", "qty", "min", "max")} for k, v in data["items"].items()},
    }


def fixed_random(client, value):
    """Pins the answer delay so the order of answers is known."""
    client.lua.execute("math.random = function() return %s end" % value)


def b36(n):
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    out = ""
    while True:
        n, d = divmod(n, 36)
        out = digits[d] + out
        if n == 0:
            return out


def whisper(client, sender, origin, records):
    client.fire("CHAT_MSG_ADDON", "DropTables", "D|%s|%s" % (origin, ";".join(records)), "WHISPER", sender)


def counts(npc, kills, opened, items=()):
    """Records of one bucket: kills, all lootable, opened corpses, and (item, drops) pairs."""
    records = ["M%s.1.%s.%s.%s.0.0.." % (b36(npc), b36(kills), b36(kills), b36(opened))]
    records += ["I%s.1.%s.%s.%s.1.1" % (b36(npc), b36(item), b36(drops), b36(drops)) for item, drops in items]
    return records


def form_party(*clients):
    for client in clients:
        client.g.groupMembers = client.lua.table(*[c.name for c in clients if c is not client])


def flushes(messages):
    """Splits messages into group sends: a gap of 30 seconds or more starts a new one."""
    out = []
    for message in messages:
        if out and message[4] - out[-1][-1][4] < 30:
            out[-1].append(message)
        else:
            out.append([message])
    return out


def origin_id(n):
    return "%016x" % (0xa00000000000000 + n)


def hold(client, npc, sources):
    """Puts other installs' counts straight into a client's store: {origin: (kills, [(item, drops)][, opened])}."""
    for origin, spec in sources.items():
        kills, items = spec[0], spec[1]
        opened = spec[2] if len(spec) > 2 else kills
        item_table = ", ".join("[%d] = { drops = %d, qty = %d, min = 1, max = 1 }" % (i, d, d) for i, d in items)
        client.lua.execute("""
            local peers = DropTablesDB.peers[%d] or {}
            DropTablesDB.peers[%d] = peers
            peers["%s"] = { t = 1, maps = {}, buckets = { [1] = { kills = %d, lootable = %d, opened = %d,
                items = { %s }, money = { drops = 0, copper = 0 } } } }
        """ % (npc, npc, origin, kills, kills, opened, item_table))


def main():
    alice, bob, carol = Client("Alice"), Client("Bob"), Client("Carol")
    fixed_random(alice, 0)
    net = Net(alice, bob, carol)
    net.run(10)  # everyone joins the channel

    for spawn in ("A1", "A2", "A3"):
        loot_mob(alice, 1, spawn, [(100, 2), (101, 1)], copper=12)
    start = len(net.log)
    alice.see(1, "A1", 5)
    alice_id = alice.ns.db.installId
    net.run(10)
    expect("nobody answers their own question", net.sent(None, "D|", start), [])

    # Carol asks on the channel, Alice whispers her counts back to Carol only.
    start = len(net.log)
    carol.see(1, "C1", 5)
    net.run(10)
    expect("carol asked on the channel", [m[2] for m in net.sent("Carol", "Q|", start)], ["CHANNEL"])
    answers = net.sent("Alice", "D|", start)
    expect("alice whispered to carol", sorted({(m[2], m[3]) for m in answers}), [("WHISPER", "Carol")])
    expect("messages fit 255 bytes", max(len(m[1]) for m in net.log) <= 255, True)
    stored = carol.ns.db.peers[1][alice_id]
    expect("carol keeps alice's counts", bucket_view(stored.buckets[1]), bucket_view(alice.ns.db.mobs[1][1]))
    expect("level travels", (stored.minLevel, stored.maxLevel), (5, 5))
    expect("bob keeps nothing he did not ask for", bob.ns.db.peers[1], None)
    expect("no player names stored", "Alice" in repr(plain(carol.ns.db.peers)), False)

    stats = carol.ns.GetStats(1, "all")
    expect("peer kills counted", (stats.kills, stats.ownKills, stats.sources), (3, 0, 1))
    expect("three corpses of another player give no rates yet", len(list(stats.list.values())), 0)
    carol.ns.settings.onlyMine = True
    expect("only mine hides peer counts", carol.ns.GetStats(1, "all"), None)
    carol.ns.settings.onlyMine = False

    # The question lists what the asker holds: Alice has nothing newer for Carol, Bob's own counts are new.
    loot_mob(bob, 1, "B1", [(100, 1)])
    net.run(600)
    start = len(net.log)
    carol.see(1, "C2", 5)
    net.run(10)
    question = net.sent("Carol", "Q|", start)[0][1]
    expect("question names alice's install and kills", question.endswith("|" + alice_id[:6] + "3"), True)
    expect("alice stays quiet", net.sent("Alice", "D|", start), [])
    expect("bob answers with his own", [m[1].split("|")[1] for m in net.sent("Bob", "D|", start)],
           [bob.ns.db.installId])
    # More kills make Alice's counts worth sending again.
    loot_mob(alice, 1, "A4", [(100, 1)])
    net.run(600)
    start = len(net.log)
    carol.see(1, "C3", 5)
    net.run(10)
    expect("newer counts sent", len(net.sent("Alice", "D|", start)) >= 1, True)
    expect("carol has the update", carol.ns.db.peers[1][alice_id].buckets[1].kills, 4)

    # One player whispers at most three installs, the biggest first.
    frank, ivan, george = Client("Frank"), Client("Ivan"), Client("George")
    net.add(frank, ivan, george)
    fixed_random(frank, 0)
    fixed_random(ivan, 0.99)
    hold(frank, 8, {origin_id(i): (10 + i, [(100, 3)]) for i in range(6)})
    net.run(10)
    start = len(net.log)
    george.see(8, "G1", 5)
    net.run(10)
    frank_origins = [m[1].split("|")[1] for m in net.sent("Frank", "D|", start)]
    expect("three installs from frank, biggest first", frank_origins, [origin_id(i) for i in (5, 4, 3)])

    # A question ends once the asker holds 100 looted corpses: a big source answers fast and the next one,
    # still waiting, stays quiet. (Each scenario uses fresh players: one sender brings three new installs a day.)
    big, medium, tiny, mid = Client("Big"), Client("Medium"), Client("Tiny"), Client("Mid")
    net.add(big, medium, tiny, mid)
    for client, value in ((big, 0), (medium, 0.99), (tiny, 0), (mid, 0.99)):
        fixed_random(client, value)
    hold(big, 12, {origin_id(20): (150, [(100, 30)])})
    hold(medium, 12, {origin_id(21): (60, [(100, 12)])})
    hold(tiny, 13, {origin_id(22): (3, [(100, 1)])})
    hold(mid, 13, {origin_id(23): (60, [(100, 12)])})
    net.run(10)
    start = len(net.log)
    george.see(12, "G2", 5)
    net.run(10)
    expect("big source answered", george.ns.db.peers[12][origin_id(20)] is not None, True)
    expect("george called it off", len(net.sent("George", "C|", start)), 1)
    expect("second source stayed quiet", net.sent("Medium", "D|", start), [])

    # Bigger sources answer first when the sample is still short.
    net.run(6)
    start = len(net.log)
    george.see(13, "G3", 5)
    net.run(10)
    order = [m[0] for m in net.sent(None, "D|", start)]
    expect("60 corpses answer before 3", order, ["Mid", "Tiny"])

    # A mob the player already holds 100 corpses of is not asked about.
    hold(george, 14, {origin_id(24): (120, [(100, 30)])})
    net.run(6)
    start = len(net.log)
    george.see(14, "G4", 5)
    net.run(10)
    expect("well known mob not asked about", net.sent("George", "Q|", start), [])

    # The sample is looted corpses: many kills with few opened corpses still need more.
    hold(george, 16, {origin_id(25): (150, [(100, 30)], 60)})
    net.run(6)
    start = len(net.log)
    george.see(16, "G5", 5)
    net.run(10)
    expect("kills without corpses still asked about", len(net.sent("George", "Q|", start)), 1)

    # Many small sources: the asker stops after ten installs.
    kate = Client("Kate")
    givers = [Client("Giver%d" % i) for i in range(5)]
    net.add(kate, *givers)
    for n, giver in enumerate(givers):
        hold(giver, 15, {origin_id(30 + 3 * n + i): (3, [(100, 1)]) for i in range(3)})
    net.run(10)
    start = len(net.log)
    kate.see(15, "K1", 5)
    net.run(15)
    expect("ten installs at most per question", len(plain(kate.ns.db.peers[15])), 10)
    expect("kate called it off", len(net.sent("Kate", "C|", start)), 1)

    jack = Client("Jack")
    net.add(jack)
    hold(jack, 8, {origin_id(i): (10, [(100, 3)]) for i in range(50, 52)})
    net.run(10)
    start = len(net.log)
    jack.see(8, "J1", 5)
    net.run(10)
    expect("jack asked", len(net.sent("Jack", "Q|", start)), 1)
    expect("jack does not answer himself", net.sent("Jack", "D|", start), [])

    # Answers nobody asked for are not taken, and neither are counts on the channel, even for an open question.
    whisper(carol, "Mallory", origin_id(30), counts(6, 10, 10, [(100, 5)]))
    expect("unasked whisper ignored", carol.ns.db.peers[6], None)
    net.run(6)
    carol.see(5, "C5", 5)
    net.run(2)
    carol.fire("CHAT_MSG_ADDON", "DropTables", "D|%s|%s" % (origin_id(31), ";".join(counts(5, 9, 9))),
               "CHANNEL", "Pete")
    expect("channel answer ignored", carol.ns.db.peers[5], None)

    # One sender brings at most three installs the player has never seen; known ones may be updated by anyone.
    for i in range(40, 45):
        whisper(carol, "Mallory", origin_id(i), counts(5, 10, 10, [(100, 5)]))
    expect("three new installs per sender", len(plain(carol.ns.db.peers[5])), 3)
    whisper(carol, "Nina", origin_id(45), counts(5, 10, 10))
    expect("another sender may bring new ones", carol.ns.db.peers[5][origin_id(45)] is not None, True)
    whisper(carol, "Mallory", origin_id(40), counts(5, 20, 20))
    expect("known install updated by anyone", carol.ns.db.peers[5][origin_id(40)].buckets[1].kills, 20)

    # Malformed and impossible answers to an open question are ignored.
    fake = origin_id(50)
    net.run(6)
    carol.see(35, "C35", 5)
    net.run(2)
    for records in (["Mz.1.a.b.1.0.0.."],                     # lootable above kills
                    ["Mz.1.a.a.a.0.0..", "M6.1.a.a.a.0.0.."],  # two mobs in one answer
                    ["Iz.1.2s.0.0.."],                        # an item that dropped zero times
                    ["Mz.1.a.a.a.0.0..", "Nz.|cffff0000Evil"], # name with an escape code
                    ["Mz.1.123456789.a.a.0.0.."]):             # number too long
        whisper(carol, "Olga", fake, records)
    carol.fire("CHAT_MSG_ADDON", "DropTables", "D|nothex|Mz.1.a.a.a.0.0..", "WHISPER", "Olga")
    whisper(carol, "Olga", carol.ns.db.installId, ["Mz.1.a.a.a.0.0.."])
    expect("garbage not stored", carol.ns.db.peers[35][fake] if carol.ns.db.peers[35] else None, None)
    expect("own install id not stored",
           carol.ns.db.peers[35][carol.ns.db.installId] if carol.ns.db.peers[35] else None, None)
    whisper(carol, "Olga", fake, ["Mz.1.a.a.a.0.0.."])
    expect("the same answer, well formed, is taken", carol.ns.db.peers[35][fake] is not None, True)

    # At most twelve other installs per mob; the oldest go first, however big they are. One question takes at most
    # ten, so the twelve come from two questions.
    net.run(6)
    carol.see(7, "C7", 5)
    net.run(2)
    for i in range(10):
        corpses = 9 if i < 2 else 5
        whisper(carol, "Sender%d" % i, origin_id(60 + i), counts(7, corpses, corpses, [(100, 3)]))
        carol.advance(1)
    net.run(600)
    carol.see(7, "C7b", 5)
    net.run(2)
    for i in range(10, 14):
        whisper(carol, "Sender%d" % i, origin_id(60 + i), counts(7, 5, 5, [(100, 3)]))
        carol.advance(1)
    kept = sorted(plain(carol.ns.db.peers[7]).keys())
    expect("twelve sources kept", len(kept), 12)
    expect("oldest dropped, not smallest", origin_id(60) in kept or origin_id(61) in kept, False)

    # Rates of other players go through their median: one liar does not move them.
    hold(carol, 9, {origin_id(80 + i): (40, [(100, 12 + 2 * i)]) for i in range(3)})
    hold(carol, 9, {origin_id(90): (3000, [(100, 3000), (555, 3000)])})
    # A small source with a wild rate stays out of the rates until enough small ones add up.
    hold(carol, 9, {origin_id(91): (20, [(100, 20)])})

    def rates_of(npc):
        return {e.itemId: e for e in carol.ns.GetStats(npc, "all").list.values() if e.itemId}

    rates = rates_of(9)
    expect("honest rate kept", round(rates[100].rate, 2), round((12 + 14 + 16) / 120, 2))
    expect("item only the liar reports left out", 555 in rates, False)
    expect("big and small sources in the totals", carol.ns.GetStats(9, "all").kills, 3 * 40 + 300 + 20)
    droppers = [d.npc for d in carol.ns.FindDroppers(100).values()]
    expect("finder lists a mob known only from others", 9 in droppers, True)
    expect("finder leaves out a mob without rates", 1 in droppers, False)

    # Three sources of ten corpses each count together once they reach thirty.
    net.run(6)
    carol.see(10, "C10", 5)
    net.run(2)
    whisper(carol, "Small0", origin_id(100), counts(10, 10, 10, [(100, 5)]))
    whisper(carol, "Small1", origin_id(101), counts(10, 10, 10, [(100, 5)]))
    expect("twenty pooled corpses give no rate", len(list(carol.ns.GetStats(10, "all").list.values())), 0)
    whisper(carol, "Small2", origin_id(102), counts(10, 10, 10, [(100, 5)]))
    expect("thirty pooled corpses give a rate", round(rates_of(10)[100].rate, 2), 0.5)

    # A rare item: a 40-corpse source that saw it three times is noise around 2%, not a liar.
    hold(carol, 11, {origin_id(110 + i): (100, [(777, 2)]) for i in range(3)})
    hold(carol, 11, {origin_id(113): (40, [(777, 3)])})
    expect("noisy rare source kept", rates_of(11)[777].drops, 2 * 3 + 3)

    # With sharing off a player neither asks nor answers.
    erin = Client("Erin")
    net.add(erin)
    net.run(10)
    alice.ns.settings.shareData = False
    loot_mob(alice, 2, "A9", [(100, 1)])
    start = len(net.log)
    erin.see(2, "E1", 5)
    alice.see(3, "A9", 5)
    net.run(10)
    expect("alice off sends nothing", net.sent("Alice", None, start), [])
    alice.ns.settings.shareData = True

    # Party members send each other their own changed counts once a minute, without being asked.
    pat, quinn = Client("Pat"), Client("Quinn")
    net.add(pat, quinn)
    form_party(pat, quinn)
    net.run(70)
    start = len(net.log)
    loot_mob(pat, 20, "P1", [(100, 2)], copper=5)
    net.run(65)
    pat_id = pat.ns.db.installId
    sent = net.sent("Pat", "D|", start)
    expect("party send", sorted({m[2] for m in sent}), ["PARTY"])
    expect("member has the counts", bucket_view(quinn.ns.db.peers[20][pat_id].buckets[2]),
           bucket_view(pat.ns.db.mobs[20][2]))
    start = len(net.log)
    net.run(130)
    expect("nothing changed, nothing sent", net.sent("Pat", "D|", start), [])

    # Counts from someone outside the group are not taken; members bring as many installs as they have.
    quinn.fire("CHAT_MSG_ADDON", "DropTables", "D|%s|%s" % (origin_id(200), ";".join(counts(21, 5, 5))),
               "PARTY", "Stranger")
    expect("non-member ignored", quinn.ns.db.peers[21], None)
    for i in range(5):
        quinn.fire("CHAT_MSG_ADDON", "DropTables", "D|%s|%s" % (origin_id(201 + i), ";".join(counts(21, 5, 5))),
                   "PARTY", "Pat")
    expect("member not held to three new installs", len(plain(quinn.ns.db.peers[21])), 5)

    # One send carries at most ten messages; the rest goes a minute later.
    for npc in range(30, 45):
        pat.lua.execute("""
            DropTablesDB.mobs[%d] = { [2] = { kills = 3, lootable = 3, opened = 3,
                items = { [100] = { drops = 1, qty = 1, min = 1, max = 1 } }, money = { drops = 0, copper = 0 } } }
        """ % npc)
        pat.fire("DT_COUNTS_CHANGED", npc, 2)
    start = len(net.log)
    net.run(130)
    sends = flushes(net.sent("Pat", "D|", start))
    expect("ten messages, then the rest", [len(f) for f in sends], [10, 5])
    expect("one group message per tick", len({m[4] for m in sends[0]}), 10)

    # Nothing goes out in a lockdown; it follows once the lockdown ends.
    pat.lua.execute("C_ChatInfo.InChatMessagingLockdown = function() return true end")
    loot_mob(pat, 22, "P2", [(100, 1)])
    start = len(net.log)
    net.run(70)
    expect("nothing sent in a lockdown", net.sent("Pat", None, start), [])
    pat.lua.execute("C_ChatInfo.InChatMessagingLockdown = function() return false end")
    net.run(5)
    expect("sent after the lockdown", len(net.sent("Pat", "D|", start)) >= 1, True)

    # With sharing off nothing goes to the group, and counts from the group are still kept.
    pat.ns.settings.shareData = False
    loot_mob(pat, 23, "P3", [(100, 1)])
    start = len(net.log)
    net.run(130)
    expect("sharing off, no group send", net.sent("Pat", None, start), [])
    loot_mob(quinn, 24, "Q1", [(100, 1)])
    net.run(70)
    expect("sharing off still keeps group counts", pat.ns.db.peers[24][quinn.ns.db.installId] is not None, True)
    pat.ns.settings.shareData = True

    # Counts in db.relay, saved by the 0.1.0 bridge mode, move to db.peers.
    old = ('DropTablesDB = { installId = "%s", mobs = {}, settings = { bridgeMode = true },'
           ' relay = { ["%s"] = { t = 1, mobs = { [9] = { [1] = { kills = 4, lootable = 4, opened = 4, items = {'
           ' [100] = { drops = 2, qty = 2, min = 1, max = 1 } }, money = { drops = 0, copper = 0 } } } },'
           ' info = { [9] = { minLevel = 3, maxLevel = 4, maps = { [12] = { kills = 4, cells = {} } } } } } } }'
           % ("1" * 16, "2" * 16))
    upgraded = Client("Old", saved=old)
    peer = upgraded.ns.db.peers[9]["2" * 16]
    expect("relay migrated", (peer.buckets[1].kills, peer.buckets[1]["items"][100].drops, peer.maps[12]), (4, 2, 4))
    expect("relay and bridge setting removed", (upgraded.ns.db.relay, upgraded.ns.settings.bridgeMode), (None, None))

    # /dt debug puts a chat line for every message in and out, with the reason when one is not taken.
    def debug_lines(client):
        lines = client.g.debugLines
        return [lines[i] for i in range(1, len(lines) + 1)]

    for client in (pat, quinn):
        client.lua.execute("debugLines = {}; print = function(text) table.insert(debugLines, text) end")
        client.g.SlashCmdList.DROPTABLES("debug")
    quinn.fire("CHAT_MSG_ADDON", "DropTables", "D|%s|%s" % (origin_id(210), ";".join(counts(25, 5, 5))),
               "PARTY", "Stranger")
    stranger = "\n".join(debug_lines(quinn))
    expect("debug shows the message", "got PARTY from Stranger: D||" in stranger, True)
    expect("debug names the group as the game does", 'sender "Stranger" is not in the group' in stranger
           and "(Pat)" in stranger, True)
    loot_mob(pat, 26, "P4", [(100, 1)])
    net.run(70)
    expect("debug shows the send", any("sent PARTY D||" in line for line in debug_lines(pat)), True)
    expect("debug shows it stored", any("stored: mob 26 from group member Pat" in line for line in debug_lines(quinn)),
           True)
    quinn.g.SlashCmdList.DROPTABLES("debug")
    quinn.lua.execute("debugLines = {}")
    quinn.fire("CHAT_MSG_ADDON", "DropTables", "D|%s|%s" % (origin_id(211), ";".join(counts(25, 5, 5))),
               "PARTY", "Stranger")
    expect("debug off is quiet", debug_lines(quinn), [])

    report("sharing")


if __name__ == "__main__":
    main()
