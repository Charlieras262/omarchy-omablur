#!/usr/bin/env python3
"""Patch four Omarchy system files to add a shared Style.shellOpacity token
and read it from the bar-popup card, the notification card, and the menu
card, so this plugin can dim the whole shell (not just windows) to a
partial opacity while its own blur is on -- Hyprland only renders blur
behind a surface that isn't fully opaque.

Each card's own background color is forced to alpha 1 before Style.shellOpacity
is applied, so the result is an absolute opacity, not a multiplier stacked on
top of whatever background-alpha the user's theme (shell.toml) already bakes
into that color -- shellOpacity's default of 1 always means truly, fully
opaque, even for a theme that ships translucent by default.

Every file falls back to shellOpacity's default (1, fully opaque) when this
plugin never touches it, so this is a no-op until Omablur actually sets it.
Idempotent and safe to re-run: skips files already patched, and refuses to
touch a file whose expected original snippet isn't found (e.g. a newer
Omarchy release changed it) rather than guessing.

Must run as root, since all four files live under /usr/share/omarchy/. Run:
  sudo python3 patches/apply.py
"""

import os
import stat
import sys
import tempfile

PATCHES = [
    {
        "path": "/usr/share/omarchy/shell/Commons/Style.qml",
        "marker": "shellOpacity",
        "old": (
            "  property int cornerRadius: 0\n"
            "  property int gapsOut: 5\n"
        ),
        "new": (
            "  property int cornerRadius: 0\n"
            "  property int gapsOut: 5\n"
            "  // Shared opacity token for the shell's own surfaces (bar, popup\n"
            "  // panels, notifications, the menu). A plugin like Omablur sets this\n"
            "  // to a partial value while Hyprland blur is on -- blur only renders\n"
            "  // behind a surface that isn't fully opaque -- and back to 1 when it's\n"
            "  // off. 1 (fully opaque) leaves everything looking exactly as today.\n"
            "  property real shellOpacity: 1\n"
        ),
    },
    {
        "path": "/usr/share/omarchy/shell/Ui/KeyboardPanel.qml",
        "marker": "Style.shellOpacity",
        "old": (
            "    color: Color.popups.background\n"
            "    borderSpec: root.borderSpec\n"
            "    padding: root.padding\n"
            "    radius: Style.cornerRadius\n"
            "    opacity: root.open || root.popoutSwitching ? 1.0 : 0\n"
        ),
        "new": (
            "    // Color.popups.background can carry its own baked-in alpha\n"
            "    // (shell.toml's [popups] background-alpha); forcing it to 1 here\n"
            "    // first means Style.shellOpacity below is an absolute result, not\n"
            "    // a multiplier on top of an already-translucent color -- a plugin\n"
            "    // that never touches shellOpacity still reaches exactly opaque.\n"
            "    color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 1)\n"
            "    borderSpec: root.borderSpec\n"
            "    padding: root.padding\n"
            "    radius: Style.cornerRadius\n"
            "    opacity: (root.open || root.popoutSwitching ? 1.0 : 0) * Style.shellOpacity\n"
        ),
    },
    {
        "path": "/usr/share/omarchy/shell/plugins/notifications/components/NotificationCard.qml",
        "marker": "Style.shellOpacity",
        "old": (
            "  radius: cornerRadius\n"
            "  color: Color.notifications.background\n"
            "  borderSpec: cardBorderSpec\n"
            "  clip: true\n"
        ),
        "new": (
            "  radius: cornerRadius\n"
            "  // Forced to alpha 1 so Style.shellOpacity below is an absolute\n"
            "  // result, not a multiplier on top of shell.toml's own\n"
            "  // [notifications] background-alpha.\n"
            "  color: Qt.rgba(Color.notifications.background.r, Color.notifications.background.g, Color.notifications.background.b, 1)\n"
            "  opacity: Style.shellOpacity\n"
            "  borderSpec: cardBorderSpec\n"
            "  clip: true\n"
        ),
    },
    {
        "path": "/usr/share/omarchy/shell/plugins/menu/Menu.qml",
        "marker": "Style.shellOpacity",
        "old": (
            "      color: root.background\n"
            "      borderSpec: root.borderSpec\n"
            "      padding: root.contentMargin\n"
        ),
        "new": (
            "      // Forced to alpha 1 so Style.shellOpacity below is an absolute\n"
            "      // result, not a multiplier on top of shell.toml's own [menu]\n"
            "      // background-alpha.\n"
            "      color: Qt.rgba(root.background.r, root.background.g, root.background.b, 1)\n"
            "      opacity: Style.shellOpacity\n"
            "      borderSpec: root.borderSpec\n"
            "      padding: root.contentMargin\n"
        ),
    },
]


def refuse_symlink(path: str) -> None:
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return
    if stat.S_ISLNK(st.st_mode):
        raise OSError("refusing symlink: %s" % path)


def apply_one(spec: dict) -> None:
    path = spec["path"]
    if not os.path.isfile(path):
        print(f"skip (not found): {path}")
        return
    refuse_symlink(path)
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    if spec["marker"] in text:
        print(f"already patched: {path}")
        return
    if spec["old"] not in text:
        print(
            f"WARNING: expected snippet not found, leaving untouched "
            f"(Omarchy may have changed this file since this patch was written): {path}",
            file=sys.stderr,
        )
        return

    backup = path + ".pre-omablur-patch.bak"
    if not os.path.exists(backup):
        with open(backup, "w", encoding="utf-8") as f:
            f.write(text)

    patched = text.replace(spec["old"], spec["new"], 1)
    parent = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix=".patch.", suffix=".tmp", dir=parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(patched)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    print(f"patched: {path}")


def main() -> int:
    if os.geteuid() != 0:
        print("Run with sudo: sudo python3 patches/apply.py", file=sys.stderr)
        return 1
    for spec in PATCHES:
        apply_one(spec)
    print("Done. Run: omarchy restart shell")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
