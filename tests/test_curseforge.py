"""Uploads to CurseForge (tools/curseforge_upload.py) against a stand-in for its API, in a throwaway git repository:
what goes in each zip, the changelogs, the dependency and when the data addon is uploaded again.

Requires: pip install lupa
Run: python tests/test_curseforge.py
"""
import io
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "tools"))
from wowsim import expect, report  # noqa: E402
import curseforge_upload  # noqa: E402

ENV = {"CF_API_TOKEN": "token", "CF_ADDON_PROJECT": "111", "CF_DATA_PROJECT": "222", "CF_DATA_SLUG": "data-slug"}
VERSIONS = [{"id": 17053, "gameVersionTypeID": 88568, "name": "1.60.1", "apiVersion": "16001"},
            {"id": 1, "gameVersionTypeID": 2, "name": "1.15.8", "apiVersion": "11508"}]


class FakeCurseForge:
    def __init__(self):
        self.uploads = []

    def __call__(self, request):
        expect("the token goes in its header", request.get_header("X-api-token"), "token")
        if request.get_method() == "GET":
            return VERSIONS
        body = request.data
        meta = json.loads(re.search(rb'name="metadata"\r\n\r\n(.*?)\r\n--', body, re.S).group(1))
        data = re.search(rb"Content-Type: application/zip\r\n\r\n(.*)\r\n--[0-9a-f]+--\r\n$", body, re.S).group(1)
        names = sorted(zipfile.ZipFile(io.BytesIO(data)).namelist())
        self.uploads.append((request.full_url, meta, names))
        return {"id": 1000 + len(self.uploads)}


def repo(root):
    def write(path, text):
        (root / path).parent.mkdir(parents=True, exist_ok=True)
        (root / path).write_text(text, encoding="utf-8")

    def git(*args):
        return subprocess.run(["git", *args], cwd=root, check=True, capture_output=True, text=True).stdout

    def commit(message):
        git("add", "-A")
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message)

    return write, git, commit


def shared(mobs):
    return json.dumps({"mobs": {str(n): {"buckets": {"1": {"kills": k, "items": {}}}} for n, k in mobs.items()}})


def runs(root):
    write, git, commit = repo(root)
    git("init", "-q")
    write("DropTables/DropTables.toc", "## Interface: 16001\n## Version: 0.7.0\n\nCore.lua\n")
    write("DropTables/Core.lua", "-- addon\n")
    write("CHANGELOG.md", "# Changelog\n\n## [0.7.0] - 2026-11-28\n\n### Changed\n\n- The database is its own addon."
                          "\n\n## [0.6.5] - 2026-11-27\n\n- Older.\n")
    write("DropTables_Data/DropTables_Data.toc", "## Interface: 16001\n## Version: 2026.11.28\n\nApi.lua\nData.lua\n")
    write("DropTables_Data/Data.lua", "-- data\n")
    write("data/shared.json", shared({1: 10, 2: 20}))
    write("data/submissions/3-1.json", "{}")
    write("data/imports/eglink.json", "{}")
    commit("first")
    pushed = []

    def run(command, **kwargs):
        if command[:2] == ["git", "push"]:
            pushed.append(command[2:])
            return subprocess.CompletedProcess(command, 0, "", "")
        return subprocess.run(command, **kwargs)

    args = ["--root", str(root)]
    cf = FakeCurseForge()
    expect("the data goes up", curseforge_upload.main(["data"] + args, env=ENV, run=run, send=cf), 0)
    url, meta, names = cf.uploads[-1]
    expect("to the data project", url, "https://wow.curseforge.com/api/projects/222/upload-file")
    expect("with only the data folder", names, ["DropTables_Data/", "DropTables_Data/Data.lua",
                                                "DropTables_Data/DropTables_Data.toc"])
    expect("for WoW Forever", meta["gameVersions"], [17053])
    expect("named after the build", (meta["displayName"], meta["releaseType"]),
           ("Forever Drop Tables Data 2026.11.28", "release"))
    expect("the first changelog has the totals", meta["changelog"],
           "Database 2026.11.28.\n\n- 2 mobs\n- 30 kills\n- 0 skinned corpses")
    expect("and the upload is tagged", (git("tag", "--list").split(), pushed), (["data-2026.11.28"],
                                                                                [["origin", "data-2026.11.28"]]))
    expect("the same version doesn't go up twice",
           curseforge_upload.main(["data"] + args, env=ENV, run=run, send=cf), 0)
    expect("so one upload", len(cf.uploads), 1)

    # A new share replaces an older export of the same player, and EG Link is refreshed.
    (root / "data" / "submissions" / "3-1.json").unlink()
    write("data/submissions/18-1.json", "{}")
    write("data/imports/eglink.json", '{"new": 1}')
    write("data/shared.json", shared({1: 15, 2: 20, 3: 5}))
    write("DropTables_Data/DropTables_Data.toc", "## Interface: 16001\n## Version: 2026.11.29\n\nApi.lua\nData.lua\n")
    commit("second")
    curseforge_upload.main(["data"] + args, env=ENV, run=run, send=cf)
    expect("the next changelog says what changed", cf.uploads[-1][1]["changelog"],
           "Database 2026.11.29.\n\n- 3 mobs (+1)\n- 40 kills (+10)\n- 0 skinned corpses (+0)\n"
           "- Shares from players: #18\n- Refreshed counts from EG Link")

    git("tag", "v0.7.0")
    curseforge_upload.main(["addon", "--ref", "v0.7.0", "--release-type", "beta"] + args, env=ENV, run=run, send=cf)
    url, meta, names = cf.uploads[-1]
    expect("the addon goes to its own project", url, "https://wow.curseforge.com/api/projects/111/upload-file")
    expect("with only its folder", names, ["DropTables/", "DropTables/Core.lua", "DropTables/DropTables.toc"])
    expect("as a beta", (meta["displayName"], meta["releaseType"]), ("Forever Drop Tables 0.7.0", "beta"))
    expect("with its changelog section", meta["changelog"], "### Changed\n\n- The database is its own addon.")
    expect("and the data addon as a required dependency", meta["relations"],
           {"projects": [{"slug": "data-slug", "projectID": "222", "type": "requiredDependency"}]})
    expect("no tag for the addon", sorted(git("tag", "--list").split()),
           ["data-2026.11.28", "data-2026.11.29", "v0.7.0"])

    write("DropTables/DropTables.toc", "## Interface: 16001\n## Version: 0.7.1\n\nCore.lua\n")
    commit("third")
    try:
        curseforge_upload.main(["addon"] + args, env=ENV, run=run, send=cf)
        stopped = False
    except SystemExit:
        stopped = True
    expect("a version without a changelog section isn't uploaded", (stopped, len(cf.uploads)), (True, 3))


def main():
    with tempfile.TemporaryDirectory() as folder:
        runs(pathlib.Path(folder))
    report("CurseForge upload")


if __name__ == "__main__":
    main()
