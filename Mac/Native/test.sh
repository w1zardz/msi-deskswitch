#!/bin/bash
set -euo pipefail
task_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
task_root="$(cd -- "$task_dir/../.." && pwd)"
mkdir -p "$task_root/dist"
/usr/bin/xcrun swiftc -parse-as-library "$task_dir/Core.swift" "$task_dir/Keyboard.swift" "$task_dir/HotKeys.swift" "$task_dir/Tests.swift" -o "$task_root/dist/tests"
"$task_root/dist/tests"
