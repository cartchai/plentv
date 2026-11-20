#!/usr/bin/env python3
"""Guard that Sentry stays out of the Apple SwiftPM locks.

1.6.11 L1 finished the Sentry strip: `sentry_flutter` is gone from the
Flutter graph (no pubspec entry, no `Sentry.` calls left in `lib/`), so
neither Apple lockfile may carry a `sentry-cocoa` pin. This check fails
if a pin creeps back into either `Package.resolved`, or if
`sentry_flutter` reappears in the resolved Flutter packages.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

LOCK_PATHS = (
    Path("ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"),
    Path("macos/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"),
)
SENTRY_IDENTITY = "sentry-cocoa"
SENTRY_PACKAGE = "sentry_flutter"


def _load_pin_map(path: Path, errors: list[str]) -> dict[str, dict]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        errors.append(f"{path}: cannot read version-2 SwiftPM lock: {error}")
        return {}
    if not isinstance(payload, dict) or payload.get("version") != 2 or not isinstance(payload.get("pins"), list):
        errors.append(f"{path}: expected a version-2 SwiftPM lock with a pins array")
        return {}

    pins: dict[str, dict] = {}
    for pin in payload["pins"]:
        identity = pin.get("identity") if isinstance(pin, dict) else None
        if not isinstance(identity, str):
            errors.append(f"{path}: pin without a string identity")
            continue
        if identity in pins:
            errors.append(f"{path}: duplicate pin identity {identity}")
        pins[identity] = pin if isinstance(pin, dict) else {}
    return pins


def _check_resolved_packages(root: Path, errors: list[str]) -> None:
    config_path = root / ".dart_tool/package_config.json"
    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        errors.append(f"{config_path}: unavailable ({error}); run flutter pub get first")
        return
    packages = config.get("packages") if isinstance(config, dict) else None
    if not isinstance(packages, list):
        errors.append(f"{config_path}: missing packages list; run flutter pub get first")
        return
    if any(isinstance(item, dict) and item.get("name") == SENTRY_PACKAGE for item in packages):
        errors.append(f"{config_path}: {SENTRY_PACKAGE} is resolved; Sentry was stripped in 1.6.11")


def validate(root: Path) -> list[str]:
    root = root.resolve()
    errors: list[str] = []
    for relative_path in LOCK_PATHS:
        path = root / relative_path
        pins = _load_pin_map(path, errors)
        if SENTRY_IDENTITY in pins:
            errors.append(f"{path}: {SENTRY_IDENTITY} pin is present; Sentry was stripped in 1.6.11")
    _check_resolved_packages(root, errors)
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args(argv)
    errors = validate(args.root)
    if errors:
        for error in errors:
            print(f"error: {error}")
        return 1
    print("Apple SwiftPM locks contain no Sentry pins.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
