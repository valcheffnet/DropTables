"""The Drop Tables Debug addon (debug/DropTablesDebug), a test helper that isn't part of the Drop Tables download.

Requires: pip install lupa
Run: python tests/test_debug.py
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from wowsim import ADDON_DIR, FINDER_STUBS, Client, expect, report  # noqa: E402

TAB_STUBS = """
    groupsRemoved = 0
    tabsOpened = 0
    FCF_OpenNewWindow = function(name)
        chatWindowNames[4], chatWindowShown[4], tabsOpened = name, nil, tabsOpened + 1
        return ChatFrame4
    end
    FCF_Close = function(frame) if frame == ChatFrame4 then chatWindowNames[4] = nil end end
    ChatFrame_RemoveAllMessageGroups = function(frame) if frame == ChatFrame4 then groupsRemoved = 1 end end
"""


def toggle(client):
    client.g.SlashCmdList.DROPTABLESDEBUG("")


def without_the_addon():
    plain = Client("Plain")
    plain.ns.Debug("nobody listens %d", 1)
    expect("without the debug addon the lines go nowhere", len(plain.g.ChatFrame1.lines), 0)
    expect("and Drop Tables has no debug command", plain.g.SlashCmdList.DROPTABLESDEBUG, None)
    old = Client("Old", saved="DropTablesDB = { settings = { debug = true }, debugLog = { 'one' } }")
    expect("the old debug switch and lines are cleared", (old.ns.settings.debug, old.ns.db.debugLog), (None, None))
    toc = (ADDON_DIR / "DropTables.toc").read_text(encoding="utf-8")
    expect("the Drop Tables toc doesn't load it", "Debug" in toc, False)


def tab():
    """/dtdebug is saved and opens its own chat tab with no other messages in it."""
    tester = Client("Debugger", saved=TAB_STUBS, debug=True)
    expect("off at first", tester.g.DropTablesDebugDB.on, None)
    toggle(tester)
    expect("on is saved", tester.g.DropTablesDebugDB.on, True)
    expect("debug tab opened", (tester.g.chatWindowNames[4], tester.g.groupsRemoved), ("DT Debug", 1))
    expect("the first line says how sharing stands", "channel" in (tester.g.ChatFrame4.lines[1] or ""), True)
    tester.ns.Debug("mob %d", 7)
    expect("Drop Tables' lines reach the tab", "mob 7" in (tester.g.ChatFrame4.lines[2] or ""), True)
    toggle(tester)
    expect("off closes the tab", (tester.g.DropTablesDebugDB.on, tester.g.chatWindowNames[4]), (False, None))
    tester.lua.execute("ChatFrame1.lines = {}; ChatFrame4.lines = {}")
    tester.ns.Debug("while off")
    expect("off is quiet", (len(tester.g.ChatFrame1.lines), len(tester.g.ChatFrame4.lines)), (0, 0))
    toggle(tester)
    expect("on opens it again", tester.g.chatWindowNames[4], "DT Debug")
    # The tab is hidden while another tab of the dock is selected, and the lines still go only to it.
    tester.lua.execute("chatWindowShown[4], chatWindowDocked[4] = false, 2; ChatFrame1.lines = {}; ChatFrame4.lines = {}")
    opened = tester.g.tabsOpened
    tester.ns.Debug("while General is selected")
    expect("a hidden docked tab gets the line, no new tab and none in General",
           (len(tester.g.ChatFrame4.lines), tester.g.tabsOpened - opened, len(tester.g.ChatFrame1.lines)), (1, 0, 0))
    # A tab closed by hand while debug is on opens again with the next line.
    tester.lua.execute("chatWindowDocked[4] = nil")
    tester.ns.Debug("after the tab was closed")
    expect("a closed tab opens again", (tester.g.tabsOpened - opened, len(tester.g.ChatFrame4.lines),
                                        len(tester.g.ChatFrame1.lines)), (1, 2, 0))


def badge():
    """Lines that come while the DT Debug tab is behind another one are counted on its tab, and bringing it to the
    front clears the count."""
    badger = Client("Badger", saved=FINDER_STUBS, debug=True)
    badger.lua.execute("""
        hooks = {}
        local function hookable(t, name)
            t.shown = false
            t.GetName = function() return name end
            t.IsShown = function(self) return self.shown end
            t.HookScript = function(_, script, fn) hooks[name .. script] = fn end
        end
        hookable(ChatFrame4, "ChatFrame4")
        ChatFrame4Tab = {}
        hookable(ChatFrame4Tab, "ChatFrame4Tab")
        ChatFrame4Tab.shown = true
        FCF_OpenNewWindow = function(name) chatWindowNames[4] = name; return ChatFrame4 end
        FCF_Close = function(frame) chatWindowNames[4] = nil end
    """)
    toggle(badger)
    for i in range(3):
        badger.ns.Debug("line %d", i)
    shown = badger.debug_ns.badge
    expect("hidden tab counts its new lines", (shown.shown, shown.text.text), (True, "4"))
    badger.lua.execute("ChatFrame4.shown = true; hooks.ChatFrame4OnShow(ChatFrame4)")
    expect("bringing the tab to the front clears the count", shown.shown, False)
    badger.ns.Debug("read right away")
    expect("a line seen as it comes counts nothing", shown.shown, False)
    badger.lua.execute("ChatFrame4.shown = false")
    for i in range(120):
        badger.ns.Debug("line %d", i)
    expect("more than 99 shows 99+", shown.text.text, "99+")
    badger.lua.execute("ChatFrame4Tab.shown = false; hooks.ChatFrame4TabOnHide()")
    expect("no badge while the tab itself is hidden", shown.shown, False)
    badger.lua.execute("ChatFrame4Tab.shown = true; hooks.ChatFrame4TabOnShow()")
    expect("the badge comes back with the tab", shown.shown, True)
    toggle(badger)
    expect("debug off hides the badge", shown.shown, False)


def reload():
    """A /reload puts the kept lines back into the tab, and a new login forgets them."""
    reloaded = Client("Reloaded", saved="DropTablesDebugDB = { on = true, log = { 'one', 'two' } }", debug=True)
    reloaded.ns.Debug("after a reload")
    expect("debug still on after a reload", len(reloaded.g.ChatFrame1.lines), 1)
    reloaded.lua.execute("ChatFrame1.lines = {}")
    reloaded.fire("PLAYER_ENTERING_WORLD", False, True)
    expect("a reload puts the kept lines back", [reloaded.g.ChatFrame1.lines[i] for i in (1, 2)], ["one", "two"])
    expect("the line before the reload is kept too", "after a reload" in (reloaded.g.ChatFrame1.lines[3] or ""), True)
    reloaded.fire("PLAYER_ENTERING_WORLD", False, False)
    expect("zoning puts nothing back", len(reloaded.g.ChatFrame1.lines), 3)
    for i in range(510):
        reloaded.ns.Debug("line %d", i)
    log = reloaded.g.DropTablesDebugDB.log
    expect("only the last 500 lines are kept", (len(log), "line 509" in log[500]), (500, True))
    again = reloaded.reload()
    expect("the switch and lines survive a reload", (again.g.DropTablesDebugDB.on, len(again.g.DropTablesDebugDB.log)),
           (True, 500))
    again.fire("PLAYER_ENTERING_WORLD", True, False)
    expect("a new login starts with none", len(again.g.DropTablesDebugDB.log), 0)
    again.ns.Debug("again")
    toggle(again)
    expect("debug off forgets the kept lines", len(again.g.DropTablesDebugDB.log), 0)


def main():
    without_the_addon()
    tab()
    badge()
    reload()
    report("debug")


if __name__ == "__main__":
    main()
