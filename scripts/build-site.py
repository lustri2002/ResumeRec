#!/usr/bin/env python3
"""Render the static landing using published GitHub release metadata."""

import argparse
from datetime import datetime
import html
import json
from pathlib import Path
import re
import shutil
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "https://github.com/lustri2002/ResumeRec"
ASSETS = ("styles.css", ".nojekyll", "images/app-icon.png", "images/recording-settings.png")


def select_release(pages):
    """Include prereleases, ignore drafts, and sort by publication (not tag date)."""
    releases = [release for page in pages for release in page] if pages and isinstance(pages[0], list) else pages
    published = [r for r in releases if not r.get("draft") and r.get("published_at")]
    if not published:
        raise ValueError("No published release found; keeping the existing website.")
    release = max(published, key=lambda r: (datetime.fromisoformat(r["published_at"].replace("Z", "+00:00")), r["id"]))
    tag = release["tag_name"]
    assets = [a for a in release.get("assets", []) if a.get("state") == "uploaded" and a.get("size", 0) > 0]
    installers = [a for a in assets if re.fullmatch(r"ResumeRec-.+-arm64\.dmg", a["name"])]
    if len(installers) != 1:
        raise ValueError(f"Release {tag} needs exactly one uploaded ResumeRec-*-arm64.dmg.")
    installer = installers[0]
    checksums = [a for a in assets if a["name"] == installer["name"] + ".sha256"]
    if len(checksums) != 1:
        raise ValueError(f"Release {tag} is missing its matching uploaded .dmg.sha256 file.")
    for asset in (installer, checksums[0]):
        expected = f"{REPOSITORY}/releases/download/{quote(tag, safe='')}/{quote(asset['name'], safe='')}"
        if asset["browser_download_url"] != expected:
            raise ValueError(f"Unexpected asset URL for {asset['name']}.")
    return {
        "tag": tag,
        "download_url": installer["browser_download_url"],
        "release_url": f"{REPOSITORY}/releases/tag/{quote(tag, safe='')}",
        "label": f"{'Free public beta' if release.get('prerelease') else 'Free download'} · {tag}",
    }


def render(template, release):
    replacements = {
        "DOWNLOAD_URL": (release["download_url"], 3),
        "RELEASE_URL": (release["release_url"], 1),
        "RELEASE_LABEL": (release["label"], 1),
    }
    for key, (value, expected_count) in replacements.items():
        token = "{{" + key + "}}"
        if template.count(token) != expected_count:
            raise ValueError(f"Expected {expected_count} occurrences of {token}; check the landing template.")
        template = template.replace(token, html.escape(value, quote=True))
    if re.search(r"\{\{[^{}]+\}\}", template):
        raise ValueError("The landing contains unresolved template placeholders.")
    return template


def build(releases_path, output):
    release = select_release(json.loads(releases_path.read_text()))
    rendered = render((ROOT / "docs/index.html").read_text(), release)
    # Copy only public site assets, never the ignored local notes in docs/.
    if output.exists():
        raise ValueError(f"Output already exists: {output}. Choose a fresh output directory.")
    output.mkdir(parents=True)
    for asset in ASSETS:
        destination = output / asset
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / "docs" / asset, destination)
    (output / "index.html").write_text(rendered)
    print(f"Website built for {release['tag']}: {release['download_url']}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--releases", type=Path, required=True, help="JSON from gh api --paginate --slurp repos/OWNER/REPO/releases")
    parser.add_argument("--output", type=Path, required=True, help="A new directory for the static site")
    args = parser.parse_args()
    try:
        build(args.releases, args.output)
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.exit(1, f"Website build failed: {error}\n")
