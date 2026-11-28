"""Uploads Forever Drop Tables or Forever Drop Tables Data to CurseForge, each as its own project, so the CurseForge
app matches every folder to one project.

    python tools/curseforge_upload.py addon --ref v0.7.0 [--release-type beta]
        Zips the DropTables folder of that tag and uploads it with its section of CHANGELOG.md, with the data project
        as a required dependency, so the app installs both.
    python tools/curseforge_upload.py data [--ref HEAD]
        Zips DropTables_Data when its version differs from the last one uploaded, with a changelog of what changed
        since then, and marks the upload with the tag data-<version>. Without a change it uploads nothing.

Needs CF_API_TOKEN, CF_ADDON_PROJECT and CF_DATA_PROJECT (project ids) and CF_DATA_SLUG (the data project's slug, for
the dependency) in the environment. The game version is the WoW Forever one whose API version matches the toc's
Interface line.
"""
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import urllib.request
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
HOST = "https://wow.curseforge.com"
USER_AGENT = "droptables-release (https://github.com/valcheffnet/DropTables)"
sys.path.insert(0, str(ROOT / "tools"))
import build_data  # noqa: E402


def toc_field(text, field):
    match = re.search(r"^## %s: (.+?)\s*$" % re.escape(field), text, re.M)
    return match.group(1) if match else None


def changelog_section(changelog, version):
    """The text under "## [version]" in CHANGELOG.md, without the heading."""
    match = re.search(r"^## \[%s\][^\n]*\n(.*?)(?=^## \[|\Z)" % re.escape(version), changelog, re.M | re.S)
    if not match:
        raise SystemExit("CHANGELOG.md has no section for %s." % version)
    return match.group(1).strip()


def data_changelog(version, before, after, shares, refreshed):
    """Markdown for a data upload: the totals with what changed since the last upload, the shares that went in and the
    imports that were refreshed. before is None for the first upload."""
    now = build_data.measures(after)
    lines = ["Database %s." % version, ""]
    for name in ("mobs", "kills", "skinned corpses"):
        change = "" if before is None else " (%+d)" % (now[name] - build_data.measures(before)[name])
        lines.append("- %s %s%s" % ("{:,}".format(now[name]), name, change))
    if shares:
        lines.append("- Shares from players: %s" % ", ".join("#%d" % n for n in shares))
    if refreshed:
        lines.append("- Refreshed counts from %s" % " and ".join(refreshed))
    return "\n".join(lines)


def multipart(fields, file_name, file_bytes):
    boundary = uuid.uuid4().hex
    parts = []
    for name, value in fields.items():
        parts.append(('--%s\r\nContent-Disposition: form-data; name="%s"\r\n\r\n%s\r\n' % (boundary, name, value))
                     .encode("utf-8"))
    parts.append(('--%s\r\nContent-Disposition: form-data; name="file"; filename="%s"\r\n'
                  "Content-Type: application/zip\r\n\r\n" % (boundary, file_name)).encode("utf-8"))
    parts.append(file_bytes + b"\r\n--%s--\r\n" % boundary.encode())
    return b"".join(parts), "multipart/form-data; boundary=" + boundary


def http(request):
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.loads(response.read())


class CurseForge:
    def __init__(self, token, send=http):
        self.token, self.send = token, send

    def request(self, path, data=None, content_type=None):
        headers = {"X-Api-Token": self.token, "User-Agent": USER_AGENT}
        if content_type:
            headers["Content-Type"] = content_type
        return self.send(urllib.request.Request(HOST + path, data=data, headers=headers,
                                                method="POST" if data else "GET"))

    def game_versions(self, interface):
        found = [v["id"] for v in self.request("/api/game/versions") if str(v.get("apiVersion")) == interface]
        if not found:
            raise SystemExit("CurseForge has no game version for Interface %s." % interface)
        return found

    def upload(self, project, metadata, file_name, file_bytes):
        body, content_type = multipart({"metadata": json.dumps(metadata)}, file_name, file_bytes)
        return self.request("/api/projects/%s/upload-file" % project, body, content_type)["id"]


def main(argv, env=None, run=subprocess.run, send=http):
    sys.stdout.reconfigure(encoding="utf-8")
    env = os.environ if env is None else env
    mode = argv[0] if argv and argv[0] in ("addon", "data") else None
    if not mode:
        raise SystemExit(__doc__)
    ref = argv[argv.index("--ref") + 1] if "--ref" in argv else "HEAD"
    release_type = argv[argv.index("--release-type") + 1] if "--release-type" in argv else "release"
    root = pathlib.Path(argv[argv.index("--root") + 1]) if "--root" in argv else ROOT

    def git(*args, binary=False):
        return run(["git", *args], cwd=root, check=True, capture_output=True, text=not binary).stdout

    def show(path, at=ref):
        return git("show", "%s:%s" % (at, path))

    folder = "DropTables" if mode == "addon" else "DropTables_Data"
    toc = show("%s/%s.toc" % (folder, folder))
    version = toc_field(toc, "Version")
    cf = CurseForge(env["CF_API_TOKEN"], send)
    if mode == "addon":
        title = "Forever Drop Tables %s" % version
        metadata = {"changelog": changelog_section(show("CHANGELOG.md"), version), "changelogType": "markdown",
                    "relations": {"projects": [{"slug": env["CF_DATA_SLUG"], "projectID": env["CF_DATA_PROJECT"],
                                               "type": "requiredDependency"}]}}
        project, tag = env["CF_ADDON_PROJECT"], None
    else:
        tags = [t for t in git("tag", "--list", "data-*", "--sort=-creatordate").split() if t]
        last = tags[0] if tags else None
        if last == "data-" + version:
            print("Forever Drop Tables Data %s is already on CurseForge." % version)
            return 0
        before = json.loads(show("data/shared.json", last)) if last else None
        # Submissions that came in since; an older one a player's new export replaced only goes away.
        added = git("diff", "--name-only", "--no-renames", "--diff-filter=A", last, ref, "--",
                    "data/submissions").split() if last else []
        shares = sorted({int(m.group(1)) for path in added for m in [re.search(r"/(\d+)-\d+\.json$", path)] if m})
        changed = git("diff", "--name-only", last, ref, "--", "data/imports").split() if last else []
        refreshed = [name for name, path in (("EG Link", "data/imports/eglink.json"),
                                             ("Everloot", "data/imports/everloot.json")) if path in changed]
        title = "Forever Drop Tables Data %s" % version
        after = json.loads(show("data/shared.json"))
        metadata = {"changelog": data_changelog(version, before, after, shares, refreshed), "changelogType": "markdown"}
        project, tag = env["CF_DATA_PROJECT"], "data-" + version
    metadata.update(displayName=title, releaseType=release_type,
                    gameVersions=cf.game_versions(toc_field(toc, "Interface")))
    with tempfile.TemporaryDirectory() as temp:
        archive = pathlib.Path(temp) / "upload.zip"
        git("-c", "core.autocrlf=false", "archive", "--format=zip", "-o", str(archive), ref, folder)
        file_id = cf.upload(project, metadata, "%s-%s.zip" % (folder, version), archive.read_bytes())
    print("Uploaded %s to CurseForge as file %s (%s)." % (title, file_id, release_type))
    if tag:
        git("tag", tag, ref)
        git("push", "origin", tag)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
