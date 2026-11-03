"""Refreshes the offline snapshots bundled into the APK.

The app downloads both sources at runtime and only falls back to these when the
network is unavailable, so they are stored in the raw form and parsed by the very
same Dart code that parses a fresh download. That way the two can never drift
apart.

Run from the repository root:

    python tool/update_snapshots.py
"""

from __future__ import annotations

import os
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "assets", "data")

PEERS_ZIP = "https://codeload.github.com/yggdrasil-network/public-peers/zip/refs/heads/master"
WIKI_RAW = "https://yggwiki.cc/yggdrasil:sites_and_services:other_network_services?do=export_raw"
DNS_RAW = "https://yggwiki.cc/yggdrasil:dns:internal_dns?do=export_raw"


def fetch(url: str, timeout: int = 60) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "Y-Node-snapshot/1.0"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def write(name: str, data: bytes) -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, name)
    with open(path, "wb") as handle:
        handle.write(data)
    print(f"wrote {path} ({len(data)} bytes)")


def main() -> int:
    try:
        write("public-peers.zip", fetch(PEERS_ZIP))
    except Exception as error:  # noqa: BLE001 - a snapshot refresh is best effort
        print(f"public-peers snapshot failed: {error}", file=sys.stderr)

    try:
        write("wiki_services.txt", fetch(WIKI_RAW))
    except Exception as error:  # noqa: BLE001
        print(f"wiki services snapshot failed: {error}", file=sys.stderr)

    try:
        write("wiki_dns.txt", fetch(DNS_RAW))
    except Exception as error:  # noqa: BLE001
        print(f"wiki dns snapshot failed: {error}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
