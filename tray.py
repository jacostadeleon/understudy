#!/usr/bin/env python3
"""understudy tray/controller for macOS (NSStatusBar) and Linux (AppIndicator/pystray fallback).

One click: starts the proxy if needed, parks a status-bar/tray icon:
  - green / red / orange dot shows proxy health (polled every 5 s)
  - left click (mac) / left or right click (linux): menu
  - menu: Launch Claude Code, Show journal, Refresh, Start/Stop proxy,
          Route this project via <model>, Quit (stops the proxy)

Zero pip dependencies beyond Pillow for the tray drawing:
    pip3 install --user pillow
(on Linux a desktop-status-notifier host such as GNOME's AppIndicator extension
or any KDE/Unity session is also required; macOS needs nothing extra.)
"""

import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

DIR = Path(__file__).resolve().parent
CONFIG_PATH = DIR / "config.json"
SELECTED_PATH = DIR / "selected.json"
PORT = int(os.environ.get("UNDERSTUDY_PORT", "8793"))
BASE = f"http://127.0.0.1:{PORT}"

IS_MAC = sys.platform == "darwin"
IS_LINUX = sys.platform.startswith("linux")


# ---------------- core helpers (shared logic with tray.ps1) ----------------

def health(timeout=2.0):
    try:
        with urllib.request.urlopen(f"{BASE}/healthz", timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except Exception:
        return None


def port_free():
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(0.4)
    try:
        s.connect(("127.0.0.1", PORT))
        return False
    except OSError:
        return True
    finally:
        s.close()


def spawn_proxy():
    """Start proxy.mjs detached, with the parent-death watchdog wired."""
    if not port_free():
        return True
    env = dict(os.environ)
    env["UNDERSTUDY_PARENT_PID"] = str(os.getpid())
    try:
        kwargs = {}
        if not IS_MAC:
            kwargs["stdout"] = subprocess.DEVNULL
            kwargs["stderr"] = subprocess.DEVNULL
        proc = subprocess.Popen(
            ["node", str(DIR / "proxy.mjs")],
            cwd=str(DIR),
            env=env,
            start_new_session=True,  # detach from our process group
            **kwargs,
        )
        STATE["proxy_pid"] = proc.pid
        return True
    except FileNotFoundError:
        STATE["error"] = "node not found in PATH"
        return False


def wait_health(attempts=20):
    for _ in range(attempts):
        if health():
            return True
        time.sleep(0.25)
    return False


def stop_proxy():
    try:
        req = urllib.request.Request(
            f"{BASE}/shutdown", method="POST", data=b"{}"
        )
        urllib.request.urlopen(req, timeout=3).read()
    except Exception:
        pass
    pid = STATE.get("proxy_pid")
    if pid:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        STATE["proxy_pid"] = None
    for _ in range(10):
        if port_free():
            break
        time.sleep(0.2)


def config_models():
    try:
        cfg = json.loads(CONFIG_PATH.read_text())
    except Exception:
        return []
    models = []
    default_provider = cfg.get("default_provider")
    for name, meta in (cfg.get("models") or {}).items():
        models.append(
            {
                "provider": meta.get("provider", default_provider),
                "model": name,
                "label": meta.get("label", name),
            }
        )
    return models


def set_selection(provider, model):
    SELECTED_PATH.write_text(json.dumps({"provider": provider, "model": model}))


def clear_selection():
    SELECTED_PATH.write_text(json.dumps({"default": True}))


def selection_label():
    h = health()
    if h:
        sel = h.get("selected") or {}
        if sel.get("default"):
            return "default (Claude haiku)"
        if sel.get("model"):
            return f"{sel.get('provider')}/{sel['model']}"
    try:
        sel = json.loads(SELECTED_PATH.read_text())
        if sel.get("default"):
            return "default (Claude haiku)"
        return f"{sel['provider']}/{sel['model']}"
    except Exception:
        return "unset"


def launch_claude():
    if not health():
        spawn_proxy()
        wait_health()
    env = dict(os.environ)
    env["ANTHROPIC_BASE_URL"] = BASE
    env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
    if IS_MAC:
        # Terminal.app window running claude, detaches from us
        subprocess.Popen(["open", "-a", "Terminal", str(DIR)], env=env)
        time.sleep(1.0)
        script = (
            'tell application "Terminal" to do script '
            f"'cd {DIR} && claude' in window 1"
        )
        subprocess.run(["osascript", "-e", script], env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        term = None
        for cand in ("gnome-terminal", "konsole", "xfce4-terminal",
                     "x-terminal-emulator", "alacritty", "kitty"):
            if shutil.which(cand):
                term = cand
                break
        cmd = {
            "gnome-terminal": ["gnome-terminal", "--working-directory", str(DIR)],
            "konsole": ["konsole", "--workdir", str(DIR)],
            "xfce4-terminal": ["xfce4-terminal", "--working-directory", str(DIR)],
            "alacritty": ["alacritty", "--working-directory", str(DIR)],
            "kitty": ["kitty", "--directory", str(DIR)],
        }.get(term, [])
        if cmd:
            subprocess.Popen(cmd + ["claude"], env=env,
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
        else:
            subprocess.Popen(["claude"], cwd=str(DIR), env=env)


STATE = {"proxy_pid": None, "error": "", "stop_flag": False}


# ---------------- macOS: NSStatusBar via PyObjC ----------------

def mac_main():
    """macOS status item. Uses PyObjC if importable, else subprocess menubar
    via a tiny embedded Swift-free NSApplication loop is complex - PyObjC is
    preinstalled on recent macOS."""

    try:
        import AppKit  # noqa
        import Foundation  # noqa
        from PyObjCTools import AppHelper  # noqa
    except ImportError:
        print(
            "macOS tray needs PyObjC (preinstalled on recent macOS):\n"
            "  pip3 install --user pyobjc-framework-Cocoa\n"
            "falling back to headless mode: proxy + claude still work\n"
            "via ./und.sh, only the status icon is missing.",
            file=sys.stderr,
        )
        headless_main()
        return

    import AppKit as App  # noqa
    import Foundation as Fnd

    class AppDelegate(Fnd.NSObject):
        def initWithState_(self, state):
            self = super().init()
            self.state = state
            return self

        # dynamic menu build on open
        def menuNeedsUpdate_(self, menu):
            menu.removeAllItems()
            h = health()
            if h:
                sel = h.get("selected") or {}
                label = (
                    "default (Claude haiku)"
                    if sel.get("default")
                    else f"{sel.get('provider','?')}/{sel.get('model','?')}"
                )
                status_line = f"RUNNING  -  routing: {label}"
            else:
                status_line = f"STOPPED  -  {self.state['error'] or 'launch it below'}"
            item = App.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                status_line, None, ""
            )
            item.setEnabled_(False)
            menu.addItem_(item)
            menu.addItem_(App.NSMenuItem.separatorItem())

            route = App.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "Route this project via", None, ""
            )
            route.setEnabled_(False)
            menu.addItem_(route)

            cur = selection_label()
            mi = App.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "default (unrouted, Claude haiku)",
                "setDefault:", "",
            )
            mi.setState_(App.NSControlStateValueOn if cur.startswith("default")
                         else App.NSControlStateValueOff)
            menu.addItem_(mi)
            for m in config_models():
                label = f"{m['label']}  [{m['provider']}]"
                it = App.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                    label, "pickModel:", ""
                )
                it.setRepresentedObject_(
                    Fnd.NSString.stringWithString_(f"{m['provider']}|{m['model']}")
                )
                it.setState_(App.NSControlStateValueOn
                             if cur.endswith(m["model"])
                             else App.NSControlStateValueOff)
                menu.addItem_(it)

            menu.addItem_(App.NSMenuItem.separatorItem())
            for title, action in [
                ("Launch Claude Code here", "launchClaude:"),
                ("Show journal", "showJournal:"),
                ("Refresh status", "refresh:"),
            ]:
                it = App.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                    title, action, ""
                )
                menu.addItem_(it)
            sep = App.NSMenuItem.separatorItem()
            menu.addItem_(sep)
            it = App.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "Quit (stops the proxy)", "quit:", ""
            )
            menu.addItem_(it)

        # actions
        def setDefault_(self, sender):
            clear_selection()

        def pickModel_(self, sender):
            prov, model = str(sender.representedObject()).split("|", 1)
            set_selection(prov, model)

        def launchClaude_(self, sender):
            launch_claude()

        def refresh_(self, sender):
            pass

        def showJournal_(self, sender):
            h = health()
            lines = ["understudy journal", ""]
            if h:
                lines.append(
                    f"proxy: RUNNING (uptime {h.get('uptimeSec')}s)"
                )
                lines.append(f"passthrough: {h.get('passthrough')}")
                sel = h.get("selected") or {}
                if sel.get("default"):
                    lines.append("selected: default (Claude haiku)")
                else:
                    lines.append(
                        f"selected: {sel.get('provider')}/{sel.get('model')}"
                    )
            else:
                lines.append("proxy: STOPPED")
            text = "\n".join(lines)
            script = (
                'display dialog "'
                + text.replace('"', '\\"').replace("\n", "\\n")
                + '" with title "understudy"'
            )
            subprocess.run(["osascript", "-e", script])

        def quit_(self, sender):
            stop_proxy()
            App.NSApplication.sharedApplication().terminate_(None)

    app = App.NSApplication.sharedApplication()
    delegate = AppDelegate.alloc().initWithState_(STATE)
    app.setDelegate_(delegate)

    bar = App.NSStatusBar.systemStatusBar()
    item = bar.statusItemWithLength_(-1)  # NSVariableStatusItemLength

    def make_dot(color):
        size = Fnd.NSSize(18, 18)
        img = App.NSImage.imageWithSize_flipped_drawingHandler_(
            size, False, lambda rect: draw_dot(rect, color, Fnd)
        )
        img.setTemplate_(True)
        return img

    def draw_dot(rect, rgb, Fnd):
        color_map = {
            "green": (0.24, 0.78, 0.35),
            "red": (0.87, 0.28, 0.28),
            "orange": (1.00, 0.62, 0.20),
        }
        r, g, b = color_map[color]
        App.NSColor.colorWithSRGBRed_green_blue_alpha_(r, g, b, 1.0).setFill()
        inset = Fnd.NSInsetRect(rect, 4, 4)
        App.NSBezierPath.bezierPathWithOvalInRect_(inset).fill()
        return True

    state_ref = {"item": item, "draw": draw_dot}

    def tick():
        h = health()
        if h:
            sel = h.get("selected") or {}
            label = (
                "default"
                if sel.get("default")
                else (sel.get("model") or "").replace("[1m]", "")
            )
            item.button().setImage_(make_dot("green"))
            item.button().setToolTip_(f"understudy: {label}")
            STATE["error"] = ""
        elif not port_free():
            item.button().setImage_(make_dot("orange"))
            item.button().setToolTip_("understudy: not responding")
        else:
            item.button().setImage_(make_dot("red"))
            item.button().setToolTip_("understudy: stopped")

    menu = App.NSMenu.alloc().init()
    menu.setDelegate_(delegate)
    menu.setAutoenablesItems(False)
    item.setMenu_(menu)

    timer = Fnd.NSTimer.timerWithTimeInterval_target_selector_userInfo_repeats_(
        5.0, delegate, "tickPlaceholder:", None, True
    )
    # simpler: NSTimer with block-less target-selector needs ObjC method; use
    # AppHelper-callable:
    class Ticker(Fnd.NSObject):
        def tick_(self, _t):
            tick()

    ticker = Ticker.alloc().init()
    Fnd.NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
        5.0, ticker, "tick:", None, True
    )
    del timer

    spawn_proxy() if not health() else None
    tick()
    AppHelper.runEventLoop()


# ---------------- Linux / fallback: pystray + Pillow ----------------

def make_icon_image(kind):
    from PIL import Image, ImageDraw
    colors = {
        "green": (57, 181, 74),
        "red": (222, 88, 88),
        "orange": (255, 165, 40),
    }
    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse((10, 10, 54, 54), fill=colors[kind])
    d.ellipse((10, 10, 54, 54), outline=(120, 120, 120, 255), width=2)
    return img


def linux_menu(state, rebuild):
    import pystray
    items = []
    h = health()
    if h:
        sel = h.get("selected") or {}
        label = (
            "default (Claude haiku)"
            if sel.get("default")
            else f"{sel.get('provider','?')}/{sel.get('model','?')}"
        )
        items.append(pystray.MenuItem(f"RUNNING - routing: {label}", None, enabled=False))
    else:
        items.append(pystray.MenuItem(
            f"STOPPED - {state['error'] or 'start it below'}", None, enabled=False))
    items.append(pystray.Menu.SEPARATOR)
    items.append(pystray.MenuItem(
        "default (unrouted, Claude haiku)",
        lambda: clear_selection(),
        checked=lambda _: (selection_label().startswith("default")),
        radio=True,
    ))
    for m in config_models():
        items.append(pystray.MenuItem(
            f"{m['label']}  [{m['provider']}]",
            (lambda mm: lambda: set_selection(mm["provider"], mm["model"]))(m),
            checked=lambda _, mm=m: selection_label().endswith(mm["model"]),
            radio=True,
        ))
    items.append(pystray.Menu.SEPARATOR)
    items.append(pystray.MenuItem("Launch Claude Code here", lambda: launch_claude()))
    items.append(pystray.MenuItem("Refresh status", lambda: None))

    def toggle(item, icon):
        if health():
            stop_proxy()
        else:
            spawn_proxy()
            wait_health()
        rebuild(icon)

    items.append(pystray.MenuItem(
        "Stop proxy" if h else "Start proxy", toggle))
    items.append(pystray.MenuItem(
        "Quit (stops the proxy)", lambda: (stop_proxy(), ICON_RTN["icon"].stop())))
    return pystray.Menu(*items)


ICON_RTN = {"icon": None}


def pystray_main():
    try:
        import pystray  # noqa
    except ImportError:
        print(
            "Linux tray needs:  pip3 install --user pystray pillow\n"
            "(plus a desktop indicator host - GNOME needs the "
            "'AppIndicator support' extension)\n"
            "headless mode still works: ./und.sh launch",
            file=sys.stderr,
        )
        headless_main()
        return

    import pystray

    def current_kind():
        if health():
            return "green"
        if not port_free():
            return "orange"
        return "red"

    def rebuild(icon=None):
        target = icon or ICON_RTN["icon"]
        if not target:
            return
        target.icon = make_icon_image(current_kind())
        h = health()
        sel = (h or {}).get("selected") or {}
        label = (
            "default"
            if sel.get("default")
            else (sel.get("model") or "").replace("[1m]", "")
        )
        target.title = f"understudy: {'running - ' + label if h else 'stopped'}"
        target.menu = linux_menu(STATE, rebuild)

    def poll():
        while not STATE["stop_flag"]:
            rebuild()
            time.sleep(5)

    icon = pystray.Icon(
        "understudy",
        make_icon_image(current_kind()),
        "understudy",
        linux_menu(STATE, rebuild),
    )
    ICON_RTN["icon"] = icon
    threading.Thread(target=poll, daemon=True).start()

    if not health():
        spawn_proxy()
    with icon:
        icon.run(setup=None)


def headless_main():
    """No GUI toolkit: just keep the proxy alive and react to Ctrl+C."""
    if not health():
        spawn_proxy()
        if wait_health():
            print(f"understudy: proxy running on {BASE}")
        else:
            print("understudy: proxy failed to start", file=sys.stderr)
            sys.exit(1)
    else:
        print(f"understudy: proxy already running on {BASE}")
    try:
        while True:
            if not health() and port_free():
                spawn_proxy()
            time.sleep(5)
    except KeyboardInterrupt:
        print("\nunderstudy: stopping proxy")
        stop_proxy()


if __name__ == "__main__":
    if "--headless" in sys.argv or not (IS_MAC or IS_LINUX):
        headless_main()
    elif IS_MAC:
        mac_main()
    else:
        pystray_main()
