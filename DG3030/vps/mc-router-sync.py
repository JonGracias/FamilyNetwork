#!/usr/bin/env python3
"""mc-router-sync -- make mc-router's live routes equal /etc/mc-router/routes.json.

mc-router's own -routes-config-watch RELOADS the file when it changes, but the reload only
ADDS: a route the new file no longer has stays live until mc-router restarts. Found
2026-10-07, when world addresses became secret codes (MinecraftServers NEXT.md N21): the
pushed file named only the code, and the world's old guessable name kept answering - and
so would a stopped world's route, or a code renewed because it leaked.

Restarting mc-router on every push is not an answer: a push follows every world start, and
a restart drops every player on every world. This runs instead, from mc-router-sync.path
whenever the file changes, and talks to mc-router's local API (-api-binding
127.0.0.1:8734): every live route the file lacks is DELETED, every route the file has and
mc-router lacks (or points elsewhere) is ADDED. Connections already proxied are untouched.

Standard library only - the VPS has python3 and nothing else worth depending on.
"""

from __future__ import annotations

import json
import sys
import time
import urllib.error
import urllib.request

ROUTES_FILE = "/etc/mc-router/routes.json"
API = "http://127.0.0.1:8734"


def say(message: str) -> None:
    print(message, flush=True)  # the journal is the log


def wanted() -> dict[str, str]:
    """The file's mappings. It is written by scp, in place, so a read can land mid-write:
    a file that does not parse is read again, briefly, before giving up."""
    for _ in range(10):
        try:
            with open(ROUTES_FILE, encoding="utf-8") as fh:
                body = json.load(fh)
            return {host.lower(): backend for host, backend in body.get("mappings", {}).items()}
        except (OSError, ValueError):
            time.sleep(0.5)
    raise SystemExit(f"{ROUTES_FILE} did not parse after 5 s - leaving the live routes alone")


def call(method: str, path: str, body: dict | None = None):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(
        API + path, data=data, method=method,
        headers={"content-type": "application/json"} if data else {},
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        raw = response.read()
    return json.loads(raw) if raw.strip() else None


def main() -> int:
    file_routes = wanted()
    try:
        live = {host.lower(): route.get("backend", "")
                for host, route in (call("GET", "/routes") or {}).items()}
    except urllib.error.URLError as exc:
        say(f"mc-router's API is not answering ({exc}) - nothing synced")
        return 1

    removed = [host for host in live if host not in file_routes]
    added = [host for host, backend in file_routes.items() if live.get(host) != backend]
    for host in removed:
        call("DELETE", f"/routes/{host}")
        say(f"removed {host} (was {live[host]})")
    for host in added:
        call("POST", "/routes", {"serverAddress": host, "backend": file_routes[host]})
        say(f"routed  {host} -> {file_routes[host]}")
    say(f"in sync: {len(file_routes)} route(s), {len(removed)} removed, {len(added)} added")
    return 0


if __name__ == "__main__":
    sys.exit(main())
