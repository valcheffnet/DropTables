"""Players asking on a simulated hidden channel and whispering drop counts back.

Requires: pip install lupa
Run: python tests/test_share.py
"""
import pathlib
import re
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
        client.fire("DT_DATA_CHANGED", npc)


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
    expect("another player's three corpses give chances at once", len(list(stats.list.values())) > 0, True)
    carol.ns.settings.onlyMine = True
    carol.fire("DT_SETTINGS_CHANGED")
    expect("only mine hides peer counts", carol.ns.GetStats(1, "all"), None)
    carol.ns.settings.onlyMine = False
    carol.fire("DT_SETTINGS_CHANGED")

    # Friendly NPCs drop nothing, so targeting a flight master neither asks about it nor records it.
    start = len(net.log)
    carol.see(90, "C90", 30, friendly=True)
    net.run(10)
    expect("no question about a flight master", net.sent("Carol", "Q|", start), [])
    expect("flight master not recorded", carol.ns.db.names[90], None)

    # The question lists what the asker holds, so Alice has nothing newer for Carol while Bob's own counts are new.
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

    # A question ends once the asker holds 100 looted corpses, so a big source answers fast and the next one, still
    # waiting, stays quiet. Each scenario uses fresh players, since one sender brings three new installs a day.
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

    # A mob the player already holds 100 corpses of is asked about once a day, to keep its counts fresh. That
    # question runs until enough installs answered, not until the corpses add up.
    hold(george, 14, {origin_id(24): (120, [(100, 30)])})
    fresh = Client("Fresh")
    net.add(fresh)
    # These two ids start differently from origin_id(24), because a question names held installs by their first 6 hex.
    hold(fresh, 14, {"1a2b3c4d5e6f7081": (50, [(100, 10)]), "9f8e7d6c5b4a3920": (40, [(100, 8)])})
    net.run(6)
    start = len(net.log)
    george.see(14, "G4", 5)
    net.run(10)
    expect("well known mob asked once a day", len(net.sent("George", "Q|", start)), 1)
    expect("daily question takes more than one install", len(plain(george.ns.db.peers[14])), 3)
    net.run(130)
    start = len(net.log)
    george.see(14, "G4b", 5)
    net.run(5)
    expect("not again the same day", net.sent("George", "Q|", start), [])
    george.ns.db.refreshed[14] = george.g.time() - 86401
    george.see(14, "G4c", 5)
    net.run(5)
    expect("asked again the next day", len(net.sent("George", "Q|", start)), 1)

    # The sample counts looted corpses, so many kills with few opened corpses still need more.
    hold(george, 16, {origin_id(25): (150, [(100, 30)], 60)})
    net.run(6)
    start = len(net.log)
    george.see(16, "G5", 5)
    net.run(10)
    expect("kills without corpses still asked about", len(net.sent("George", "Q|", start)), 1)

    # The pause after a question is two minutes when someone answered and longer each time nobody did.
    paula, helper = Client("Paula"), Client("Helper")
    net.add(paula, helper)
    net.run(10)

    def asks(npc, spawn, seconds):
        begin = len(net.log)
        paula.see(npc, spawn, 5)
        net.run(seconds)
        return len(net.sent("Paula", "Q|", begin))

    expect("first question", asks(40, "P1", 2), 1)
    net.run(118)
    expect("unanswered: asked again after 2 minutes", asks(40, "P2", 2), 1)
    net.run(118)
    expect("unanswered twice: not after 2 minutes", asks(40, "P3", 2), 0)
    net.run(180)
    expect("asked again after 5 minutes", asks(40, "P4", 8), 1)
    hold(helper, 40, {origin_id(130): (20, [(100, 5)])})
    net.run(600)
    expect("asked after the longer pause", asks(40, "P5", 8), 1)
    expect("helper answered", paula.ns.db.peers[40][origin_id(130)] is not None, True)
    net.run(112)
    expect("answered: two minutes again", asks(40, "P6", 2), 1)

    # Mobs targeted during the gap wait in line, the newest three of them, but a mob asked about a moment ago doesn't.
    net.run(130)
    begin = len(net.log)
    for npc in (41, 42, 43, 44, 45):
        paula.see(npc, "Q%d" % npc, 5)
    net.run(1)
    expect("first goes out at once", [m[1].split("|")[2] for m in net.sent("Paula", "Q|", begin)], [b36(41)])
    net.run(30)
    expect("the newest three follow, one per gap",
           [m[1].split("|")[2] for m in net.sent("Paula", "Q|", begin)], [b36(n) for n in (41, 43, 44, 45)])
    begin = len(net.log)
    paula.see(41, "Q41b", 5)
    net.run(10)
    expect("recently asked mob not put in line", net.sent("Paula", "Q|", begin), [])
    # Targeting a waiting mob again does not take a second place in line and push another mob out.
    net.run(10)
    begin = len(net.log)
    for npc in (51, 52, 53, 52, 52, 54):
        paula.see(npc, "R%d" % npc, 5)
    net.run(30)
    expect("each waiting mob asked once",
           [m[1].split("|")[2] for m in net.sent("Paula", "Q|", begin)], [b36(n) for n in (51, 52, 53, 54)])

    # A mob with many items fits in a few messages, with the most frequent items going out and the rarest left out.
    giver, asker = Client("Giver"), Client("Asker")
    net.add(giver, asker)
    hold(giver, 50, {origin_id(140): (99, [(1000 + i, 60 - i) for i in range(60)])})
    net.run(10)
    begin = len(net.log)
    asker.see(50, "A50", 5)
    net.run(10)
    texts = [m[1] for m in net.sent("Giver", "D|", begin)]
    expect("at most four messages for one mob", len(texts), 4)
    joined = ";".join(texts)
    expect("most frequent item sent", ("I%s.1.%s." % (b36(50), b36(1000))) in joined, True)
    expect("rarest item left out", ("I%s.1.%s." % (b36(50), b36(1059))) in joined, False)

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

    # One sender brings at most three installs the player has never seen, while known ones may be updated by anyone.
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
                    ["Mz.1.a.a.a.0.0..", "Iz.1.2s.5.5.0."],      # stack size 0, no largest stack
                    ["Mz.1.a.a.a.0.0..", "Iz.1.2s.5.5.0.3"],     # stack size 0
                    ["Mz.1.a.a.a.1.5.0."],                       # money 0 copper at least, no most
                    ["Mz.1.123456789.a.a.0.0.."]):             # number too long
        whisper(carol, "Olga", fake, records)
    carol.fire("CHAT_MSG_ADDON", "DropTables", "D|nothex|Mz.1.a.a.a.0.0..", "WHISPER", "Olga")
    whisper(carol, "Olga", carol.ns.db.installId, ["Mz.1.a.a.a.0.0.."])
    expect("garbage not stored", carol.ns.db.peers[35][fake] if carol.ns.db.peers[35] else None, None)
    expect("own install id not stored",
           carol.ns.db.peers[35][carol.ns.db.installId] if carol.ns.db.peers[35] else None, None)
    whisper(carol, "Olga", fake, ["Mz.1.a.a.a.0.0.."])
    expect("the same answer, well formed, is taken", carol.ns.db.peers[35][fake] is not None, True)
    # Numbers have at most six base 36 digits, because tonumber would cut longer ones at 2^32.
    expect("six digits read", carol.ns.Wire.ReadNumber("zzzzzz"), 36 ** 6 - 1)
    expect("seven digits refused", carol.ns.Wire.ReadNumber("1000000"), None)

    # A mob keeps at most twelve other installs, and the oldest go first however big they are. One question takes at
    # most ten, so the twelve come from two questions.
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

    # Big sources are checked against their median, so one liar doesn't move the chances.
    hold(carol, 9, {origin_id(80 + i): (40, [(100, 12 + 2 * i)]) for i in range(3)})
    hold(carol, 9, {origin_id(90): (3000, [(100, 3000), (555, 3000)])})
    # A small source is always added, since it has too few corpses to tell a liar from luck.
    hold(carol, 9, {origin_id(91): (20, [(100, 20)])})

    def rates_of(npc):
        return {e.itemId: e for e in carol.ns.GetStats(npc, "all").list.values() if e.itemId}

    rates = rates_of(9)
    expect("honest rate kept", round(rates[100].rate, 3), round((12 + 14 + 16 + 20) / (120 + 20), 3))
    expect("drops shown match the chance", rates[100].drops, 12 + 14 + 16 + 20)
    expect("item only the liar reports left out", 555 in rates, False)
    expect("big and small sources in the totals", carol.ns.GetStats(9, "all").kills, 3 * 40 + 300 + 20)
    droppers = [d.npc for d in carol.ns.FindDroppers(100).values()]
    expect("finder lists a mob known only from others", 9 in droppers, True)
    expect("finder lists a mob from three corpses", 1 in droppers, True)

    # Small sources count at once, each added to the rest.
    net.run(6)
    carol.see(10, "C10", 5)
    net.run(2)
    whisper(carol, "Small0", origin_id(100), counts(10, 10, 10, [(100, 5)]))
    whisper(carol, "Small1", origin_id(101), counts(10, 10, 10, [(100, 5)]))
    expect("two small sources give a chance", round(rates_of(10)[100].rate, 2), 0.5)
    whisper(carol, "Small2", origin_id(102), counts(10, 10, 10, [(100, 1)]))
    expect("a third one moves it at once", round(rates_of(10)[100].rate, 3), round(11 / 30, 3))

    # A 40-corpse source that saw a rare item three times is noise around 2%, not a liar.
    hold(carol, 11, {origin_id(110 + i): (100, [(777, 2)]) for i in range(3)})
    hold(carol, 11, {origin_id(113): (40, [(777, 3)])})
    expect("noisy rare source kept", rates_of(11)[777].drops, 2 * 3 + 3)

    # Empty kills get checked as well. One install claiming thousands of kills with no loot doesn't drag every chance
    # down, while one that found a few more empty corpses than the player still counts.
    carol.lua.execute("""
        local function bucket(kills, lootable, drops)
            return { [1] = { kills = kills, lootable = lootable, opened = lootable,
                items = drops > 0 and { [100] = { drops = drops, qty = drops } } or {},
                money = { drops = 0, copper = 0 } } }
        end
        DropTablesDB.mobs[12] = bucket(20, 20, 10)
        DropTablesDB.peers[12] = { ["%s"] = { t = 1, maps = {}, buckets = bucket(5000, 0, 0) } }
    """ % origin_id(120))
    carol.fire("DT_DATA_CHANGED", 12)
    expect("fake empty kills left out", (round(rates_of(12)[100].rate, 3), carol.ns.GetStats(12, "all").kills),
           (0.5, 20))
    carol.lua.execute("""
        DropTablesDB.peers[12]["%s"] = { t = 1, maps = {}, buckets = { [1] = { kills = 40, lootable = 36,
            opened = 36, items = { [100] = { drops = 18, qty = 18 } }, money = { drops = 0, copper = 0 } } } }
    """ % origin_id(121))
    carol.fire("DT_DATA_CHANGED", 12)
    expect("honest empty kills counted", round(rates_of(12)[100].rate, 3), round(56 / 60 * 28 / 56, 3))
    # Another install counts as at most 300 kills, however few of its corpses it opened.
    hold(carol, 13, {origin_id(130): (3000, [(100, 15)], 30)})
    expect("kills of another install capped", carol.ns.GetStats(13, "all").kills, 300)


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

    # Group members are taken under whatever name the server gives them ("First Last" on Forever). A member sends
    # only their own install, so other installs from the same member are refused.
    def from_member(sender, origin, records):
        quinn.fire("CHAT_MSG_ADDON", "DropTables", "D|%s|%s" % (origin, ";".join(records)), "PARTY", sender)

    for i in range(5):
        from_member("Pat Ashwood", origin_id(201 + i), counts(21, 5, 5))
    expect("one install per member", list(plain(quinn.ns.db.peers[21]).keys()), [origin_id(201)])
    # A member brings at most 30 mobs a day that the player knows nothing of, and mobs the player knows keep coming.
    for npc in range(300, 340):
        from_member("Rae Ashwood", origin_id(210), counts(npc, 5, 5))
    expect("unknown mobs from one member capped", sum(1 for n in range(300, 340) if quinn.ns.db.peers[n]), 30)
    from_member("Rae Ashwood", origin_id(210), counts(21, 7, 7))
    expect("known mob still taken", quinn.ns.db.peers[21][origin_id(210)] is not None, True)

    # Counts split over two messages that claim more drops than looted corpses stay out of the chances.
    from_member("Sam Ashwood", origin_id(230), counts(27, 40, 40))
    from_member("Sam Ashwood", origin_id(230), ["I%s.1.%s.%s.%s.1.1" % (b36(27), b36(100), b36(120), b36(120))])
    expect("both messages kept", quinn.ns.db.peers[27][origin_id(230)].buckets[1]["items"][100].drops, 120)
    stats = quinn.ns.GetStats(27, "all")
    impossible = [e for e in stats.list.values() if e.itemId == 100] if stats else []
    expect("120 drops from 40 corpses not shown", impossible, [])

    # One send carries at most ten messages and the rest goes a minute later.
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

    # Nothing goes out during a lockdown, and it follows once the lockdown ends.
    pat.lua.execute("C_ChatInfo.InChatMessagingLockdown = function() return true end")
    loot_mob(pat, 22, "P2", [(100, 1)])
    start = len(net.log)
    net.run(70)
    expect("nothing sent in a lockdown", net.sent("Pat", None, start), [])
    pat.lua.execute("C_ChatInfo.InChatMessagingLockdown = function() return false end")
    net.run(5)
    expect("sent after the lockdown", len(net.sent("Pat", "D|", start)) >= 1, True)

    # A message that can't go out is dropped unless the server only asks to wait, so the queue keeps moving.
    pat.lua.execute("""
        tries = {}
        realSend = C_ChatInfo.SendAddonMessage
        C_ChatInfo.SendAddonMessage = function(prefix, text, chatType, target)
            local key = target or chatType
            tries[key] = (tries[key] or 0) + 1
            if target == "Gone" or target == "Two Names" then return 12 end
            if target == "Busy" and tries.Busy == 1 then return 3 end
            return realSend(prefix, text, chatType, target)
        end
    """)
    pat.fire("CHAT_MSG_ADDON", "DropTables", "Q|%s|%s|" % (origin_id(220), b36(20)), "CHANNEL", "Gone")
    pat.fire("CHAT_MSG_ADDON", "DropTables", "Q|%s|%s|" % (origin_id(221), b36(20)), "CHANNEL", "Busy")
    start = len(net.log)
    net.run(15)
    expect("offline target tried once", pat.g.tries.Gone, 1)
    expect("throttled answer goes out on a later try", (pat.g.tries.Busy, len(net.sent("Pat", "D|", start))), (2, 1))
    # A whisper to "First Last" that fails goes out once more as "First-Last".
    pat.fire("CHAT_MSG_ADDON", "DropTables", "Q|%s|%s|" % (origin_id(222), b36(20)), "CHANNEL", "Two Names")
    start = len(net.log)
    net.run(15)
    expect("whisper retried as First-Last", [m[3] for m in net.sent("Pat", "D|", start)], ["Two-Names"])
    expect("each form tried once", (pat.g.tries["Two Names"], pat.g.tries["Two-Names"]), (1, 1))
    pat.lua.execute("C_ChatInfo.SendAddonMessage = realSend")

    # The channel hands a player their own question back, and the addon doesn't answer it.
    quinn_id = quinn.ns.db.installId
    start = len(net.log)
    quinn.fire("CHAT_MSG_ADDON", "DropTables", "Q|%s|%s|" % (quinn_id, b36(21)), "CHANNEL", "Quinn Ashwood")
    net.run(15)
    expect("own question not answered", [m for m in net.sent("Quinn", None, start) if m[2] == "WHISPER"], [])

    def ask_pat(sender, asker=origin_id(250)):
        pat.fire("CHAT_MSG_ADDON", "DropTables", "Q|%s|%s|" % (asker, b36(20)), "CHANNEL", sender)

    def answers_to(sender, start):
        return [m for m in net.sent("Pat", "D|", start) if m[3] == sender]

    # A flood of questions from one player gets one answer, for the latest question.
    start = len(net.log)
    for i in range(300):
        ask_pat("Flood Ashwood", origin_id(1000 + i))
    net.run(15)
    expect("one answer for a flood of questions", len(answers_to("Flood Ashwood", start)), 1)
    # With many players at once no more than 40 answers wait, so the queue can't fill up.
    start = len(net.log)
    for i in range(60):
        ask_pat("Asker%d" % i, origin_id(1400 + i))
    net.run(40)
    expect("answers capped while many wait", len(net.sent("Pat", "D|", start)), 40)
    # Only the asker can call off the answers to them.
    start = len(net.log)
    ask_pat("Real Asker")
    pat.fire("CHAT_MSG_ADDON", "DropTables", "C|%s|%s" % (origin_id(250), b36(20)), "CHANNEL", "Mallory")
    net.run(15)
    expect("someone else's call-off ignored", len(answers_to("Real Asker", start)), 1)
    start = len(net.log)
    ask_pat("Real Asker")
    pat.fire("CHAT_MSG_ADDON", "DropTables", "C|%s|%s" % (origin_id(250), b36(20)), "CHANNEL", "Real Asker")
    net.run(15)
    expect("the asker's call-off taken", answers_to("Real Asker", start), [])

    # When the player isn't in the channel at first (a loading screen, the channel limit), the addon keeps trying and
    # asks once it's in.
    late = Client("Late")
    late.lua.execute("""
        inChannel, joins = false, 0
        GetChannelName = function() if inChannel then return 7, "DropTablesShare" end return 0 end
        JoinTemporaryChannel = function() joins = joins + 1 end
    """)
    net.add(late)
    start = len(net.log)
    net.run(40)
    late.see(20, "L1", 5)
    net.run(3)
    expect("no question outside the channel", net.sent("Late", "Q|", start), [])
    expect("joining is tried again", late.g.joins >= 2, True)
    late.lua.execute("inChannel = true")
    net.run(16)
    late.see(20, "L2", 5)
    net.run(3)
    expect("asks once in the channel", len(net.sent("Late", "Q|", start)), 1)
    late.lua.execute('GetChannelName = function() return 9, "DropTablesShare" end')
    net.run(2)
    late.see(21, "L3", 5)
    net.run(1)
    expect("question follows a new channel number", net.sent("Late", "Q|", start)[-1][3], 9)


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
    def debug_lines(client, frame=1):
        lines = client.g["ChatFrame%d" % frame].lines
        return [lines[i] for i in range(1, len(lines) + 1)]

    for client in (pat, quinn):
        client.g.SlashCmdList.DROPTABLES("debug")
    quinn.fire("CHAT_MSG_ADDON", "DropTables", "D|%s|%s" % (origin_id(210), ";".join(counts(25, 5, 5))),
               "PARTY", "Pat Ashwood")
    lines = "\n".join(debug_lines(quinn))
    expect("debug shows the message", "got PARTY from Pat Ashwood: D||" in lines, True)
    expect("debug lines carry the time", re.search(r"\d\d:\d\d:\d\d DT", lines) is not None, True)
    loot_mob(pat, 26, "P4", [(100, 1)])
    net.run(70)
    expect("debug shows the send", any("sent PARTY D||" in line for line in debug_lines(pat)), True)
    expect("debug shows it stored", any("stored: mob 26 from group member Pat" in line for line in debug_lines(quinn)),
           True)

    # A chat tab named DT Debug gets the lines instead of the main window.
    quinn.lua.execute('chatWindowNames[3] = "DT Debug"; ChatFrame1.lines = {}')
    quinn.fire("CHAT_MSG_ADDON", "DropTables", "D|%s|%s" % (origin_id(212), ";".join(counts(25, 5, 5))),
               "PARTY", "Stranger")
    expect("debug goes to the DT Debug tab", (len(debug_lines(quinn, 3)) > 0, debug_lines(quinn)), (True, []))

    quinn.g.SlashCmdList.DROPTABLES("debug")
    quinn.lua.execute("ChatFrame1.lines = {}; ChatFrame3.lines = {}")
    quinn.fire("CHAT_MSG_ADDON", "DropTables", "D|%s|%s" % (origin_id(211), ";".join(counts(25, 5, 5))),
               "PARTY", "Stranger")
    expect("debug off is quiet", debug_lines(quinn) + debug_lines(quinn, 3), [])

    report("sharing")


if __name__ == "__main__":
    main()
