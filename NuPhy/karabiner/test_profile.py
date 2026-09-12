#!/usr/bin/env python3
"""Scope, shortcut policy, artifact and non-destructive installer checks.

These are configuration checks, not a replacement for live HID/Alt-Tab tests.
"""
import copy
import json
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch
from generate import DEVICE, PREFIX, SOURCES, document
from install import install, merge, read_builtin_devices


def matches(rule, key, modifiers, device=(6645, 4141), app="com.apple.Safari", source=SOURCES[0], standard_fkeys=True):
    if rule["from"]["key_code"] != key:
        return False
    modifiers = set(modifiers)
    mandatory = set(rule["from"].get("modifiers", {}).get("mandatory", []))
    optional = set(rule["from"].get("modifiers", {}).get("optional", []))
    # Test scenarios use generic modifier names for Ctrl and exact sides for chords.
    if not mandatory <= modifiers or ("any" not in optional and modifiers - mandatory - optional):
        return False
    for condition in rule["conditions"]:
        kind = condition["type"]
        if kind == "device_if" and not any((x["vendor_id"], x["product_id"]) == device for x in condition["identifiers"]):
            return False
        if kind.startswith("frontmost_application_"):
            hit = any(re.search(pattern, app) for pattern in condition["bundle_identifiers"])
            if hit != (kind == "frontmost_application_if"):
                return False
        if kind == "input_source_if" and condition["input_sources"][0]["input_source_id"] != source:
            return False
        if kind == "variable_if":
            if condition["name"] != "system.use_fkeys_as_standard_function_keys":
                raise AssertionError("Unexpected system variable in test matcher")
            if condition["value"] is not standard_fkeys:
                return False
    return True


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.rules = document()["rules"]
        self.manipulators = [m for rule in self.rules for m in rule["manipulators"]]

    def lookup(self, key, modifiers=(), **kw):
        return next((m for m in self.manipulators if matches(m, key, modifiers, **kw)), None)

    def test_generated_artifact_matches_source(self):
        self.assertEqual(json.loads(Path(__file__).with_name("deskswitch-nuphy.json").read_text()), document())

    def test_every_rule_requires_events_from_exact_nuphy(self):
        for rule in self.manipulators:
            self.assertEqual(rule["conditions"][0], DEVICE)
            self.assertNotIn("device_exists_if", json.dumps(rule))
        self.assertIsNone(self.lookup("c", ["control"], device=(1452, 641)))
        self.assertIsNone(self.lookup("left_option", [], device=(1452, 641)))
        self.assertIsNone(self.lookup("page_down", [], device=(1452, 641)))

    def test_ctrl_and_native_cmd_tab(self):
        self.assertEqual(self.lookup("c", ["control"])["to"], [{"key_code": "c", "modifiers": ["command"]}])
        self.assertEqual(self.lookup("y", ["control"])["to"], [{"key_code": "z", "modifiers": ["command", "shift"]}])
        for modifiers in (["command"], ["control"], ["control", "shift"]):
            self.assertIsNone(self.lookup("tab", modifiers))
        self.assertIsNone(self.lookup("c", ["control", "option"]))
        self.assertIsNone(self.lookup("c", ["command"]))

    def test_terminals_keep_shell_control(self):
        for app in ("com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "net.kovidgoyal.kitty"):
            self.assertIsNone(self.lookup("c", ["control"], app=app))
            self.assertIsNone(self.lookup("r", ["control"], app=app))
            self.assertEqual(self.lookup("c", ["control", "shift"], app=app)["to"],
                             [{"key_code": "c", "modifiers": ["command"]}])

    def test_navigation(self):
        self.assertEqual(self.lookup("home")["to"], [{"key_code": "left_arrow", "modifiers": ["command"]}])
        self.assertEqual(self.lookup("end", ["control"])["to"], [{"key_code": "down_arrow", "modifiers": ["command"]}])
        self.assertEqual(self.lookup("left_arrow", ["control", "shift"])["to"],
                         [{"key_code": "left_arrow", "modifiers": ["option"]}])

    def test_language_both_orders_and_sides(self):
        for side in ("left", "right"):
            for other in ("left", "right"):
                for second, first in ((f"{side}_option", f"{other}_shift"), (f"{side}_shift", f"{other}_option")):
                    for source, target in (SOURCES, SOURCES[::-1]):
                        rule = self.lookup(second, [first], source=source)
                        self.assertEqual(rule["to"], [{"key_code": second, "modifiers": [first]}])
                        self.assertEqual(rule["to_if_alone"], [{"select_input_source": {"input_source_id": target}}])
                        self.assertEqual(rule["parameters"]["basic.to_if_alone_timeout_milliseconds"], 1500)
                        self.assertNotIn("to_after_key_up", rule)
                        self.assertNotIn("select_input_source", json.dumps(rule["to"]))

    def test_language_only_known_sources_and_no_control_chord(self):
        for rule in (self.lookup("left_option", ["left_shift"], source="unknown"),
                     self.lookup("left_option", ["left_shift", "control"])):
            self.assertNotIn("to_if_alone", rule)

    def test_alt_tab_changes_held_modifier_even_after_shift(self):
        for side in ("left", "right"):
            for modifiers in ([], ["left_shift"], ["right_shift"]):
                rule = self.lookup(f"{side}_option", modifiers)
                change = rule["to_if_other_key_pressed"][0]
                self.assertEqual(change["other_keys"], [{"key_code": "tab", "modifiers": {"optional": ["any"]}}])
                self.assertEqual(change["to"], [{"key_code": f"{side}_command"}])
                self.assertNotIn("sticky_modifier", json.dumps(rule))
                self.assertNotIn("set_variable", json.dumps(rule))

    def test_page_down_fires_only_after_release(self):
        for standard_fkeys, modifiers in ((True, ["control", "shift"]), (False, ["control", "shift", "fn"])):
            rule = self.lookup("page_down", standard_fkeys=standard_fkeys)
            self.assertEqual(rule["to"], [])
            self.assertEqual(rule["to_after_key_up"], [{"key_code": "f11", "modifiers": modifiers}])
            self.assertIsNone(self.lookup("page_down", ["control"], standard_fkeys=standard_fkeys))
            self.assertIsNone(self.lookup("page_down", standard_fkeys=standard_fkeys, device=(1452, 641)))


class InstallerTests(unittest.TestCase):
    def test_new_profile(self):
        builtins = [{"identifiers": {"is_keyboard": True}, "ignore": True}]
        result, name = merge({}, None, builtins)
        self.assertEqual(name, "DeskSwitch NuPhy")
        self.assertTrue(result["profiles"][0]["selected"])
        self.assertEqual(result["profiles"][0]["virtual_hid_keyboard"], {"keyboard_type_v2": "ansi"})
        devices = result["profiles"][0]["devices"]
        self.assertEqual(devices[:-1], builtins)
        self.assertEqual(devices[-1]["identifiers"], DEVICE["identifiers"][0])
        self.assertFalse(devices[-1]["ignore"])
        self.assertEqual(devices[-1]["fn_function_keys"], [
            {"from": {"key_code": f"f{i}"}, "to": [{"key_code": f"f{i}"}]} for i in range(1, 13)])
        self.assertNotIn("disable_built_in_keyboard_if_exists", json.dumps(result))

    def test_builtin_identity_comes_from_metadata_and_is_copied_exactly(self):
        devices = [
            {"is_built_in_keyboard": True, "device_identifiers": {"is_keyboard": True}},
            {"device_identifiers": {"vendor_id": 6645, "product_id": 4141, "is_keyboard": True}},
            {"is_built_in_pointing_device": True, "device_identifiers": {"is_pointing_device": True}},
        ]
        with patch("install.subprocess.run") as run:
            run.return_value.stdout = json.dumps(devices)
            self.assertEqual(read_builtin_devices(), [{"identifiers": {"is_keyboard": True}, "ignore": True}])
            self.assertEqual(run.call_args.args[0][-1], "--list-connected-devices")

    def test_unavailable_or_ambiguous_device_metadata_does_not_write(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "new" / "karabiner.json"
            with patch("install.subprocess.run", side_effect=FileNotFoundError()):
                with self.assertRaises(ValueError):
                    install(path, None)
            self.assertFalse(path.parent.exists())
            for devices in ([], [{"is_built_in_keyboard": True}], [
                    {"is_built_in_keyboard": True, "device_identifiers": {"is_keyboard": True}},
                    {"device_identifiers": {"is_keyboard": True}}]):
                with patch("install.subprocess.run") as run:
                    run.return_value.stdout = json.dumps(devices)
                    with self.assertRaises(ValueError):
                        install(path, None)
                self.assertFalse(path.parent.exists())

    def test_existing_profile_requires_explicit_unique_name(self):
        config = {"profiles": [{"name": "One", "selected": True}]}
        for choice in (None, "Missing"):
            with self.assertRaises(ValueError):
                merge(config, choice)
        with self.assertRaises(ValueError):
            merge({"profiles": [{"name": "Same"}, {"name": "Same"}]}, "Same")

    def test_other_settings_profiles_and_rules_are_preserved(self):
        other = {"name": "Work", "selected": True, "simple_modifications": [{"test": 1}]}
        custom = {"description": "My custom rule", "manipulators": [{"custom": True}]}
        config = {"global": {"show_in_menu_bar": False}, "profiles": [other, {
            "name": "NuPhy", "selected": False, "devices": [{"arbitrary": "preserve"}],
            "virtual_hid_keyboard": {"keyboard_type_v2": "iso", "country_code": 7},
            "complex_modifications": {"parameters": {"custom": 500}, "rules": [custom]}}]}
        original = copy.deepcopy(config)
        result, _ = merge(config, "NuPhy")
        self.assertEqual(config, original)
        self.assertEqual(result["profiles"][0], other)
        self.assertEqual(result["global"], config["global"])
        self.assertFalse(result["profiles"][1]["selected"])
        self.assertEqual(result["profiles"][1]["devices"], config["profiles"][1]["devices"])
        self.assertEqual(result["profiles"][1]["virtual_hid_keyboard"], config["profiles"][1]["virtual_hid_keyboard"])
        self.assertEqual(result["profiles"][1]["complex_modifications"]["rules"][-1], custom)
        self.assertEqual(merge(result, "NuPhy")[0], result)

    def test_modifier_swap_not_silently_overridden(self):
        config = {"profiles": [{"name": "NuPhy", "simple_modifications": [
            {"from": {"key_code": "left_option"}, "to": [{"key_code": "left_command"}]}]}]}
        with self.assertRaises(ValueError):
            merge(config, "NuPhy")

    def test_single_backup_and_invalid_selection_no_write(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "karabiner.json"
            original = b'{"profiles":[{"name":"One","selected":true}]}\n'
            path.write_bytes(original)
            with self.assertRaises(ValueError):
                install(path, "Missing")
            self.assertEqual(path.read_bytes(), original)
            self.assertFalse(path.with_name("karabiner.before-deskswitch.json").exists())
            with patch("install.read_builtin_devices", side_effect=AssertionError("Existing profile must not inspect or replace devices")):
                install(path, "One")
                install(path, "One")
            self.assertEqual(path.with_name("karabiner.before-deskswitch.json").read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
