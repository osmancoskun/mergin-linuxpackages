#!/usr/bin/env python3
"""Download RPM release assets listed in sources.txt into incoming/."""

import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "sources.txt"
INCOMING = ROOT / "incoming"
PACKAGES = ROOT / "packages"


def token():
    return os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""


def api_json(url):
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "mergin-linuxpackages",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if token():
        headers["Authorization"] = f"Bearer {token()}"
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            payload = json.load(response)
            return response.headers.get("Link", ""), payload
    except urllib.error.HTTPError as exc:
        sys.exit(f"GitHub API returned {exc.code} for {url}")


def sources():
    names = []
    for raw in SOURCES.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.count("/") != 1:
            sys.exit(f"Invalid source '{line}'. Expected owner/name.")
        names.append(line)
    return names


def already_have(name):
    return any(path.is_file() for path in PACKAGES.rglob(name))


def releases(repo):
    url = f"https://api.github.com/repos/{repo}/releases?per_page=100"
    while url:
        link, payload = api_json(url)
        if not isinstance(payload, list):
            sys.exit(f"Unexpected release list for {repo}.")
        yield from payload
        url = ""
        for part in link.split(","):
            if 'rel="next"' in part:
                url = part.split(";", 1)[0].strip().lstrip("<").rstrip(">")


def download(asset, dest):
    headers = {
        "Accept": "application/octet-stream",
        "User-Agent": "mergin-linuxpackages",
    }
    if token():
        headers["Authorization"] = f"Bearer {token()}"
    request = urllib.request.Request(asset["url"], headers=headers)
    with urllib.request.urlopen(request, timeout=180) as response, dest.open("wb") as output:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            output.write(chunk)


def main():
    INCOMING.mkdir(mode=0o755, exist_ok=True)
    for old in INCOMING.glob("*.rpm"):
        old.unlink()

    downloaded = 0
    for repo in sources():
        seen = set()
        for release in releases(repo):
            if release.get("draft"):
                continue
            tag = release.get("tag_name", "")
            for asset in release.get("assets", []):
                name = asset.get("name", "")
                if not name.endswith(".rpm") or name in seen:
                    continue
                seen.add(name)
                if already_have(name):
                    print(f"skip {repo} {tag} {name}")
                    continue
                print(f"download {repo} {tag} {name}")
                download(asset, INCOMING / name)
                downloaded += 1
    print(f"downloaded {downloaded}")


if __name__ == "__main__":
    main()
