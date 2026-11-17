"""Two players and a bridge exchanging counts over a simulated addon-message network.

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
    def __init__(self, *clients):
        self.clients = {c.name: c for c in clients}
        self.log = []
        self.drop = None

    def add(self, client):
        self.clients[client.name] = client

    def pump(self):
        moved = True
        while moved:
            moved = False
            for sender in list(self.clients.values()):
                for prefix, text, chat_type, target in sender.take_outbox():
                    moved = True
                    self.log.append((sender.name, text, chat_type, target))
                    if self.drop and self.drop(sender.name, text, chat_type, target):
                        continue
                    if chat_type == "CHANNEL":
                        for receiver in self.clients.values():
                            receiver.fire("CHAT_MSG_ADDON", prefix, text, "CHANNEL", sender.name)
                    elif chat_type == "WHISPER" and target in self.clients:
                        self.clients[target].fire("CHAT_MSG_ADDON", prefix, text, "WHISPER", sender.name)

    def run(self, seconds):
        for _ in range(seconds):
            for client in self.clients.values():
                client.advance(1)
            self.pump()


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


def main():
    alice = Client("Alice")
    bob = Client("Bob")
    bob.ns.settings.shareData = False
    net = Net(alice, bob)

    # Without a bridge nothing is whispered.
    loot_mob(alice, 1, "A1", [(100, 2), (101, 1)], copper=12)
    loot_mob(bob, 1, "B1", [(100, 1)])
    net.run(20)
    expect("no data without a bridge", [m for m in net.log if m[2] == "WHISPER"], [])

    zed = Client("Zed")
    zed.ns.SetBridgeMode(True)
    net.add(zed)
    # A second mob with many items needs several messages.
    loot_mob(alice, 2, "A2", [(1000 + i, 1 + i % 3) for i in range(40)], copper=99)
    net.run(40)

    alice_id = alice.ns.db.installId
    relay = zed.ns.db.relay
    expect("bridge stored alice", relay[alice_id] is not None, True)
    for npc in (1, 2):
        expect("mob %d relayed" % npc, bucket_view(relay[alice_id].mobs[npc][1]), bucket_view(alice.ns.db.mobs[npc][1]))
    expect("alice has nothing waiting", plain(alice.ns.db.share.dirty), {})
    data_messages = [m for m in net.log if m[0] == "Alice" and m[2] == "WHISPER"]
    expect("several data messages", len(data_messages) >= 3, True)
    expect("messages fit 255 bytes", max(len(m[1]) for m in data_messages) <= 255, True)
    expect("bob sent nothing", [m for m in net.log if m[0] == "Bob"], [])

    # Lost acknowledgements: the bridge has the data, alice resends after the timeout, totals stay right.
    net.drop = lambda sender, text, chat_type, target: sender == "Zed" and text.startswith("A|")
    # Sharing pauses while the kill is looted so exactly one up-to-date message goes out.
    alice.ns.settings.shareData = False
    loot_mob(alice, 1, "A3", [(100, 3)])
    alice.ns.settings.shareData = True
    net.run(10)
    expect("unacknowledged bucket still waiting", "1:1" in plain(alice.ns.db.share.dirty), True)
    net.drop = None
    sent_before = len([m for m in net.log if m[0] == "Alice" and m[2] == "WHISPER"])
    net.run(130)
    resent = len([m for m in net.log if m[0] == "Alice" and m[2] == "WHISPER"]) - sent_before
    expect("bucket resent after timeout", resent >= 1, True)
    expect("acknowledged after resend", plain(alice.ns.db.share.dirty), {})
    expect("duplicate does not add up", bucket_view(relay[alice_id].mobs[1][1]), bucket_view(alice.ns.db.mobs[1][1]))
    expect("kills after resend", relay[alice_id].mobs[1][1].kills, 2)

    # Levels and kill places travel too.
    expect("info relayed", plain(relay[alice_id].info), plain(alice.ns.db.info))

    # The bridge keeps no names.
    expect("no player names stored", "Alice" in repr(plain(relay)), False)

    # Malformed messages are ignored.
    zed.fire("CHAT_MSG_ADDON", "DropTables", "1|nothex|1|M1.1", "WHISPER", "Mallory")
    zed.fire("CHAT_MSG_ADDON", "DropTables", "1|0123456789abcdef|1|Mx.1.1", "WHISPER", "Mallory")
    expect("garbage not stored", relay["0123456789abcdef"], None)

    report("sharing")


if __name__ == "__main__":
    main()
