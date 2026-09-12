#!/usr/bin/env python3
"""Merge only DeskSwitch rules into an explicitly chosen Karabiner profile."""
import argparse
import copy
import json
import os
import plistlib
from pathlib import Path
import tempfile
from generate import PREFIX, document


def merge(config, profile_name):
    result = copy.deepcopy(config)
    profiles = result.setdefault("profiles", [])
    if not isinstance(profiles, list):
        raise ValueError("Некорректный список профилей Karabiner.")
    if not profiles:
        if profile_name not in (None, "DeskSwitch NuPhy"):
            raise ValueError("В новой конфигурации создаётся профиль DeskSwitch NuPhy.")
        profiles.append({"name": "DeskSwitch NuPhy", "selected": True})
        chosen = profiles[0]
    else:
        matches = [p for p in profiles if p.get("name") == profile_name]
        if len(matches) != 1:
            raise ValueError("Укажи точное уникальное имя профиля; скрытого выбора первого нет.")
        chosen = matches[0]
    # Simple modifications run before complex rules; do not silently undo a swap.
    simple = list(chosen.get("simple_modifications", []))
    for device in chosen.get("devices", []):
        ids = device.get("identifiers", {})
        if ids.get("vendor_id") == 6645 and ids.get("product_id") == 4141:
            simple += device.get("simple_modifications", [])
    modifiers = {f"{side}_{key}" for side in ("left", "right") for key in ("control", "option", "command", "shift")}
    if any(m.get("from", {}).get("key_code") in modifiers for m in simple):
        raise ValueError("В выбранном профиле уже переставлены модификаторы. Сначала убери эту перестановку вручную.")
    complex_config = chosen.setdefault("complex_modifications", {})
    old_rules = complex_config.setdefault("rules", [])
    other_rules = [r for r in old_rules if not r.get("description", "").startswith(PREFIX)]
    complex_config["rules"] = document()["rules"] + other_rules
    return result, chosen["name"]


def install(path, profile_name):
    # Reject symlinks: replacing a symlink would silently stop updating its target.
    if path.is_symlink():
        raise ValueError("Конфигурация — символическая ссылка. Укажи реальный файл через --config.")
    original = path.read_bytes() if path.exists() else None
    config = json.loads(original) if original is not None else {}
    result, name = merge(config, profile_name)
    data = (json.dumps(result, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    if data == original:
        return name
    path.parent.mkdir(parents=True, exist_ok=True)
    # A single original recovery copy, never accumulating backup versions.
    backup = path.with_name("karabiner.before-deskswitch.json")
    if original is not None and not backup.exists():
        fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(original)
    fd, temporary = tempfile.mkstemp(prefix=".deskswitch-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        # Abort if the app or another task edited the configuration meanwhile.
        current = path.read_bytes() if path.exists() else None
        if current != original:
            raise ValueError("Конфигурация изменилась во время записи. Запусти установку ещё раз.")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return name


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path.home() / ".config/karabiner/karabiner.json")
    parser.add_argument("--profile", help="Точное имя существующего профиля")
    args = parser.parse_args()
    try:
        info = Path("/Applications/Karabiner-Elements.app/Contents/Info.plist")
        if not info.exists():
            raise ValueError("Сначала установи и открой Karabiner-Elements 16.3 или новее.")
        with info.open("rb") as stream:
            version = plistlib.load(stream).get("CFBundleShortVersionString", "0")
        if tuple(int(part) for part in version.split(".")[:2]) < (16, 3):
            raise ValueError("Нужен Karabiner-Elements 16.3 или новее для надёжного удержания Alt+Tab.")
        if args.profile is None and args.config.exists():
            config = json.loads(args.config.read_text(encoding="utf-8"))
            profiles = config.get("profiles", [])
            if profiles:
                for i, profile in enumerate(profiles, 1):
                    print(f"{i}. {profile.get('name', '(без имени)')}")
                selected = input("Номер профиля для NuPhy (Enter — отмена): ").strip()
                if not selected:
                    return
                if not selected.isdigit() or not 1 <= int(selected) <= len(profiles):
                    raise ValueError("Неверный номер профиля.")
                args.profile = profiles[int(selected) - 1].get("name")
        name = install(args.config, args.profile)
        print(f"Готово: правила добавлены в «{name}». Другие профили сохранены.")
        print("Выбери этот профиль в Karabiner. В DeskSwitch выключи Ctrl-сочетания, Alt+Shift и прямую PGDN.")
        print("Запасное Ctrl+Shift+F11 в DeskSwitch оставь: через него NuPhy переключает монитор после отпускания PGDN.")
    except (ValueError, OSError, EOFError) as error:
        parser.exit(1, f"Не установлено: {error}\n")


if __name__ == "__main__":
    main()
