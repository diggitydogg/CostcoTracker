#!/usr/bin/env python3
"""Create or update the public SideStore/AltStore `source.json`.

This script owns the parts of source.json that describe the CostcoTracker
app and its release history. It is intentionally the only thing that writes
to source.json in CI so the file's shape stays consistent across runs:

- parses the existing file if present, otherwise starts from a fresh
  skeleton structure;
- preserves every previously published version entry;
- de-duplicates by exact version string (a workflow retry for the same
  version replaces that one entry instead of appending a duplicate);
- always places the newest version first, since SideStore treats the first
  compatible entry in `versions` as the latest release;
- never touches GITHUB_TOKEN or any other secret value.

Fields that are stable identifying facts about the source/app (the source
identifier, developer name, subtitle, icon URL, tint color, permission
disclosures, and the app-level description) are intentionally hardcoded as
constants below rather than passed in as CLI flags, so there is exactly one
place that defines them and the workflow invocation stays simple.
"""

import argparse
import json
import sys
from pathlib import Path

SOURCE_NAME = "CostcoTracker"
SOURCE_IDENTIFIER = "com.diggitydogg.costcotracker.source"
SOURCE_URL = (
    "https://raw.githubusercontent.com/diggitydogg/"
    "CostcoTracker/main/source.json"
)

APP_NAME = "CostcoTracker"
DEVELOPER_NAME = "Dan McGoldrick"
APP_SUBTITLE = "Track Costco purchases, prices and returns."
APP_DESCRIPTION = (
    "Track Costco purchase history, price changes, potential price "
    "matches, returns, receipts and recorded price adjustments."
)
ICON_URL = (
    "https://raw.githubusercontent.com/diggitydogg/"
    "CostcoTracker/main/icon.png"
)
TINT_COLOR = "#005DAA"

PERMISSIONS = [
    {
        "type": "camera",
        "usageDescription": (
            "CostcoTracker uses the camera to scan Costco items and "
            "receipts."
        ),
    },
    {
        "type": "photos",
        "usageDescription": (
            "CostcoTracker can save receipt and price-match cards to "
            "your photo library."
        ),
    },
    {
        "type": "network",
        "usageDescription": (
            "CostcoTracker uses network access to securely sync Costco "
            "purchase and order information."
        ),
    },
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)

    parser.add_argument(
        "--source-json",
        required=True,
        help="Path to the source.json file to create/update.",
    )
    parser.add_argument(
        "--bundle-identifier",
        required=True,
        help="CFBundleIdentifier read from the built CostcoTracker.app.",
    )
    parser.add_argument(
        "--version",
        required=True,
        help="CFBundleShortVersionString for this release, e.g. 1.0.42.",
    )
    parser.add_argument(
        "--date",
        required=True,
        help="Release date in YYYY-MM-DD (UTC).",
    )
    parser.add_argument(
        "--download-url",
        required=True,
        help="Public GitHub Release download URL for the IPA.",
    )
    parser.add_argument(
        "--size",
        required=True,
        type=int,
        help="Exact size in bytes of the built CostcoTracker.ipa.",
    )
    parser.add_argument(
        "--min-os-version",
        default=None,
        help="MinimumOSVersion read from the built Info.plist, if present.",
    )
    parser.add_argument(
        "--release-description",
        required=True,
        help="Short per-release description, e.g. a commit summary.",
    )

    return parser.parse_args()


def sanitize_text(value: str) -> str:
    """Keep source.json valid JSON/text: collapse newlines and stray
    control characters that could otherwise slip in from a commit subject
    line."""

    if value is None:
        return ""

    cleaned = value.replace("\r", " ").replace("\n", " ")
    cleaned = "".join(ch for ch in cleaned if ch == " " or ch.isprintable())
    return " ".join(cleaned.split())


def load_or_create_source(path: Path) -> dict:
    if path.exists():
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    else:
        data = {}

    data.setdefault("name", SOURCE_NAME)
    data.setdefault("identifier", SOURCE_IDENTIFIER)
    data.setdefault("sourceURL", SOURCE_URL)
    data.setdefault("apps", [])

    return data


def find_or_create_app_entry(source: dict, bundle_identifier: str) -> dict:
    for app in source["apps"]:
        if app.get("bundleIdentifier") == bundle_identifier or app.get("name") == APP_NAME:
            return app

    app = {"name": APP_NAME, "bundleIdentifier": bundle_identifier}
    source["apps"].append(app)
    return app


def upsert_version_entry(app: dict, new_entry: dict) -> None:
    versions = app.get("versions", [])

    # Replace an existing entry for the exact same version (workflow
    # retry) instead of duplicating it; everything else is preserved.
    versions = [v for v in versions if v.get("version") != new_entry["version"]]

    # Newest first: SideStore treats versions[0] as the latest release.
    versions.insert(0, new_entry)

    app["versions"] = versions


def main() -> int:
    args = parse_args()

    source_path = Path(args.source_json)
    source = load_or_create_source(source_path)

    app = find_or_create_app_entry(source, args.bundle_identifier)

    app["name"] = APP_NAME
    app["bundleIdentifier"] = args.bundle_identifier
    app["developerName"] = DEVELOPER_NAME
    app["subtitle"] = APP_SUBTITLE
    app["localizedDescription"] = APP_DESCRIPTION
    app["iconURL"] = ICON_URL
    app["tintColor"] = TINT_COLOR
    app["permissions"] = PERMISSIONS

    version_entry = {
        "version": args.version,
        "date": args.date,
        "downloadURL": args.download_url,
        "size": args.size,
        "localizedDescription": sanitize_text(args.release_description),
    }
    if args.min_os_version:
        version_entry["minOSVersion"] = args.min_os_version

    upsert_version_entry(app, version_entry)

    source_path.parent.mkdir(parents=True, exist_ok=True)
    with source_path.open("w", encoding="utf-8") as handle:
        json.dump(source, handle, indent=2, ensure_ascii=False)
        handle.write("\n")

    print(f"Updated {source_path} for version {args.version}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
