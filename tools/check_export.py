"""Checks a Drop Tables export string (DT1:...) and prints what it holds.

The string is untrusted input: nothing in it is executed, every size is capped before work is done, and every
record must match the same grammar and consistency rules as the addon's Wire.lua.

Usage:
    python tools/check_export.py FILE        (or - / nothing for stdin)
    python tools/check_export.py FILE --json (normalized data on stdout)
Exit code 0 when the string is valid, 1 with the reason on stderr when it is not.
"""
import base64
import binascii
import json
import re
import sys
import zlib

MAX_STRING = 200_000
MAX_TEXT = 2_000_000
MAX_NUMBER_DIGITS = 8
STRING_RE = re.compile(r"DT1:([A-Za-z0-9+/]+={0,2})")
HEADER_RE = re.compile(r"DTX\|1\|([0-9a-f]{16})\|([0-9A-Za-z.\-]{1,20}|\?)\|(\d{1,12})\|(\d{1,3})/(\d{1,3})")
SECTION_RE = re.compile(r"@([0-9a-f]{16})")
NUMBER_RE = re.compile(r"[0-9a-z]{0,%d}" % MAX_NUMBER_DIGITS)
MAX_NAME_BYTES = 64
NAME_RE = re.compile(r"N([0-9a-z]{1,%d})\.([^|;\x00-\x1f\x7f]+)" % MAX_NUMBER_DIGITS)

FIELDS = {
    "M": ("npc", "bucket", "kills", "lootable", "opened", "moneyDrops", "copper", "moneyMin", "moneyMax"),
    "I": ("npc", "bucket", "item", "drops", "qty", "min", "max"),
    "L": ("npc", "minLevel", "maxLevel"),
    "Z": ("npc", "map", "kills"),
    "P": ("npc", "map", "cell", "kills"),
}
REQUIRED = {"npc", "bucket", "kills", "lootable", "opened", "moneyDrops", "copper", "item", "drops", "qty", "map",
            "cell"}


class Invalid(Exception):
    pass


def decode_number(text):
    if not NUMBER_RE.fullmatch(text):
        raise Invalid("bad number %r" % text[:20])
    return int(text, 36) if text else None


def or_zero(value):
    return 0 if value is None else value


def stack_range(low, high):
    """A stack range is either missing or 1 <= min <= max."""
    if low is None or high is None:
        return low is None and high is None
    return 1 <= low <= high


def consistent(r):
    kind = r["kind"]
    if kind == "M":
        return (r["lootable"] <= r["kills"] and r["opened"] <= r["lootable"] and r["moneyDrops"] <= r["opened"]
                and (r["moneyDrops"] > 0 or r["copper"] == 0) and stack_range(r["moneyMin"], r["moneyMax"]))
    if kind == "I":
        return r["drops"] >= 1 and r["qty"] >= r["drops"] and stack_range(r["min"], r["max"])
    if kind == "L":
        return (r["minLevel"] is None) == (r["maxLevel"] is None) and or_zero(r["minLevel"]) <= or_zero(r["maxLevel"])
    return True


def decode_record(text):
    kind = text[:1]
    if kind == "N":
        match = NAME_RE.fullmatch(text)
        # Names come from the game client in its own language; the addon caps them in bytes, not characters.
        if not match or len(match.group(2).encode("utf-8")) > MAX_NAME_BYTES:
            raise Invalid("bad name record")
        return {"kind": "N", "npc": decode_number(match.group(1)), "name": match.group(2)}
    names = FIELDS.get(kind)
    if not names:
        raise Invalid("bad record kind %r" % kind)
    values = text[1:].split(".")
    if len(values) != len(names):
        raise Invalid("bad field count in %s record" % kind)
    record = {"kind": kind}
    for name, value in zip(names, values):
        record[name] = decode_number(value)
        if name in REQUIRED and record[name] is None:
            raise Invalid("missing %s in %s record" % (name, kind))
    if "bucket" in record and not 1 <= record["bucket"] <= 6:
        raise Invalid("bad bucket")
    if not consistent(record):
        raise Invalid("inconsistent %s record" % kind)
    return record


def unpack(string):
    """DT1 string -> plain text, or Invalid."""
    string = string.strip()
    if len(string) > MAX_STRING:
        raise Invalid("string longer than %d characters" % MAX_STRING)
    match = STRING_RE.fullmatch(string)
    if not match:
        raise Invalid("not a Drop Tables export string (it starts with DT1: and has no spaces)")
    try:
        packed = base64.b64decode(match.group(1), validate=True)
    except binascii.Error as error:
        raise Invalid("broken base64: %s" % error) from None
    inflater = zlib.decompressobj()
    try:
        text = inflater.decompress(packed, MAX_TEXT)
        if inflater.unconsumed_tail:
            raise Invalid("unpacks to more than %d bytes" % MAX_TEXT)
        if not inflater.eof:
            raise Invalid("string is cut short, copy all of it")
    except zlib.error:
        raise Invalid("string is damaged, copy it again") from None
    if inflater.unused_data:
        raise Invalid("extra data after the packed text")
    try:
        return text.decode("utf-8")
    except UnicodeDecodeError:
        raise Invalid("text is not UTF-8") from None


def parse(text):
    lines = text.split("\n")
    header = HEADER_RE.fullmatch(lines[0])
    if not header:
        raise Invalid("bad header line")
    part, parts = int(header.group(4)), int(header.group(5))
    if not 1 <= part <= parts:
        raise Invalid("bad part number")
    result = {
        "exporter": header.group(1), "version": header.group(2), "time": int(header.group(3)),
        "part": part, "parts": parts, "sources": {},
    }
    source = None
    for line in lines[1:]:
        section = SECTION_RE.fullmatch(line)
        if section:
            source = result["sources"].setdefault(section.group(1), {"mobs": {}})
            continue
        if source is None:
            raise Invalid("records before the first @install line")
        records = [decode_record(r) for r in line.split(";")]
        npc = records[0]["npc"]
        if any(r["npc"] != npc for r in records):
            raise Invalid("a line mixes mobs")
        add_mob(source["mobs"].setdefault(str(npc), new_mob()), records)
    if not result["sources"]:
        raise Invalid("no data")
    return result


def new_mob():
    return {"buckets": {}, "levels": None, "maps": {}, "cells": {}, "name": None}


def add_mob(mob, records):
    for r in records:
        kind = r["kind"]
        if kind in ("M", "I"):
            bucket = mob["buckets"].setdefault(str(r["bucket"]), {
                "kills": 0, "lootable": 0, "opened": 0, "money": {"drops": 0, "copper": 0}, "items": {}})
            if kind == "M":
                bucket.update(kills=r["kills"], lootable=r["lootable"], opened=r["opened"])
                bucket["money"] = {"drops": r["moneyDrops"], "copper": r["copper"], "min": r["moneyMin"],
                                   "max": r["moneyMax"]}
            else:
                bucket["items"][str(r["item"])] = {"drops": r["drops"], "qty": r["qty"], "min": r["min"],
                                                   "max": r["max"]}
        elif kind == "L":
            mob["levels"] = [r["minLevel"], r["maxLevel"]]
        elif kind == "Z":
            mob["maps"][str(r["map"])] = r["kills"]
        elif kind == "P":
            mob["cells"].setdefault(str(r["map"]), {})[str(r["cell"])] = r["kills"]
        elif kind == "N":
            mob["name"] = r["name"]
    for bucket in mob["buckets"].values():
        for item in bucket["items"].values():
            if item["drops"] > bucket["opened"]:
                raise Invalid("an item dropped more often than corpses were opened")


def check(string):
    return parse(unpack(string))


def summary(result):
    mobs = sum(len(s["mobs"]) for s in result["sources"].values())
    kills = sum(b["kills"] for s in result["sources"].values() for m in s["mobs"].values()
                for b in m["buckets"].values())
    items = {i for s in result["sources"].values() for m in s["mobs"].values() for b in m["buckets"].values()
             for i in b["items"]}
    return ("valid: part %d/%d from %s (addon %s), %d installs, %d mobs, %d kills, %d different items"
            % (result["part"], result["parts"], result["exporter"], result["version"], len(result["sources"]), mobs,
               kills, len(items)))


def main(argv):
    as_json = "--json" in argv
    paths = [a for a in argv if a != "--json"]
    if paths and paths[0] != "-":
        with open(paths[0], encoding="utf-8", errors="replace") as handle:
            string = handle.read(MAX_STRING + 1000)
    else:
        string = sys.stdin.read(MAX_STRING + 1000)
    try:
        result = check(string)
    except Invalid as error:
        print("rejected: %s" % error, file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True) if as_json else summary(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
