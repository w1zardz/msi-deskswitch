#!/usr/bin/env python3
"""Generate the NuPhy-only Karabiner 16 profile; no machine settings are changed."""
import json
from pathlib import Path

PREFIX = "DeskSwitch NuPhy — "
DEVICE = {"type": "device_if", "identifiers": [
    {"vendor_id": 6645, "product_id": 4141, "is_keyboard": True}]}
TERMINALS = [r"^com\.apple\.Terminal$", r"^com\.googlecode\.iterm2$",
             r"^dev\.warp\.warp(?:-.*)?$", r"^org\.alacritty$",
             r"^net\.kovidgoyal\.kitty$", r"^com\.github\.wez\.wezterm$"]
SOURCES = [r"^com\.apple\.keylayout\.ABC$", r"^com\.apple\.keylayout\.RussianWin$"]


def basic(key, mandatory=(), optional=("shift", "caps_lock"), to=None, conditions=()):
    modifiers = {"optional": list(optional)}
    if mandatory:
        modifiers["mandatory"] = list(mandatory)
    return {"type": "basic", "from": {"key_code": key, "modifiers": modifiers},
            "to": to or [], "conditions": [DEVICE, *conditions]}


def alt_tab(side):
    # Change the held modifier, not just flags on Tab. Karabiner releases the
    # Command on physical Option-up; Shift can be pressed/released while cycling.
    return [{"other_keys": [{"key_code": "tab", "modifiers": {"optional": ["any"]}}],
             "to": [{"key_code": f"{side}_command"}]}]


def document():
    language = []
    # The second modifier is passed through; only a modifier-only tap switches.
    # Specific sides restore exactly the mandatory modifier removed by Karabiner.
    for side in ("left", "right"):
        for other_side in ("left", "right"):
            for second, first in ((f"{side}_shift", f"{other_side}_option"),
                                  (f"{side}_option", f"{other_side}_shift")):
                for current, target in (SOURCES, SOURCES[::-1]):
                    rule = basic(second, [first], ["caps_lock"],
                                 [{"key_code": second, "modifiers": [first]}],
                                 [{"type": "input_source_if", "input_sources": [
                                     {"input_source_id": current}]}])
                    rule["to_if_alone"] = [{"select_input_source": {"input_source_id": target}}]
                    rule["parameters"] = {"basic.to_if_alone_timeout_milliseconds": 1500}
                    if second.endswith("_option"):
                        rule["to_if_other_key_pressed"] = alt_tab(side)
                    language.append(rule)
    # Lower-priority defaults cover ordinary Option+Tab and other input sources.
    for side in ("left", "right"):
        rule = basic(f"{side}_option", optional=["any"], to=[{"key_code": f"{side}_option"}])
        rule["to_if_other_key_pressed"] = alt_tab(side)
        language.append(rule)

    unless_terminal = {"type": "frontmost_application_unless", "bundle_identifiers": TERMINALS}
    in_terminal = {"type": "frontmost_application_if", "bundle_identifiers": TERMINALS}
    shortcuts = []
    for key in ("a", "s", "f", "z", "x", "c", "v", "w", "r", "t", "o", "p", "l", "n"):
        shortcuts.append(basic(key, ["control"], to=[{"key_code": key, "modifiers": ["command"]}],
                               conditions=[unless_terminal]))
    shortcuts.append(basic("y", ["control"], to=[{"key_code": "z", "modifiers": ["command", "shift"]}],
                           conditions=[unless_terminal]))
    for key in ("left_arrow", "right_arrow", "delete_or_backspace", "delete_forward"):
        shortcuts.append(basic(key, ["control"], to=[{"key_code": key, "modifiers": ["option"]}],
                               conditions=[unless_terminal]))
    for key, plain, control in (("home", "left_arrow", "up_arrow"), ("end", "right_arrow", "down_arrow")):
        shortcuts.append(basic(key, ["control"], to=[{"key_code": control, "modifiers": ["command"]}],
                               conditions=[unless_terminal]))
        shortcuts.append(basic(key, to=[{"key_code": plain, "modifiers": ["command"]}],
                               conditions=[unless_terminal]))
    for key in ("c", "v"):
        shortcuts.append(basic(key, ["control", "shift"], ["caps_lock"],
                               [{"key_code": key, "modifiers": ["command"]}], [in_terminal]))
    page_down = basic("page_down", optional=["caps_lock"])
    page_down["to_after_key_up"] = [{"key_code": "f11", "modifiers": ["control", "shift"]}]
    return {"title": "NuPhy Air100 V3: Windows shortcuts on Mac (DeskSwitch)", "rules": [
        {"description": PREFIX + "Alt+Shift и Alt+Tab", "manipulators": language},
        {"description": PREFIX + "Ctrl и навигация", "manipulators": shortcuts},
        {"description": PREFIX + "PGDN после отпускания", "manipulators": [page_down]}]}


if __name__ == "__main__":
    Path(__file__).with_name("deskswitch-nuphy.json").write_text(
        json.dumps(document(), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
