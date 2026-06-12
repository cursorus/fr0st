#!/usr/bin/env python3
"""Post Cyanide release announcements through signal-cli-rest-api.

The release script can run this locally or pipe it over SSH to the always-on
Mac mini that hosts the Signal bot. Configuration comes from SIGNAL_BOT_ENV,
which defaults in release.sh to either a local .env or the remote
~/Downloads/signal-bot/.env.
"""

import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request


def parse_env(path):
    result = {}
    path = os.path.expanduser(path)
    if not os.path.isfile(path):
        print(f"warning: Signal notify skipped: {path} not found", file=sys.stderr)
        return result
    with open(path, encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            result[key.strip()] = value.strip().strip('"').strip("'")
    return result


def compact_notes(notes):
    bullets = []
    for line in notes.splitlines():
        item = re.sub(r"^\s*[-*]\s+", "", line).strip()
        if item:
            bullets.append(item)
    if not bullets and notes.strip():
        bullets.append(" ".join(notes.split()))
    if not bullets:
        return ""

    body = "\n".join(f"• {item}" for item in bullets)
    try:
        max_chars = int(os.environ.get("SIGNAL_RELEASE_NOTES_MAX_CHARS", "2500"))
    except ValueError:
        max_chars = 2500
    if max_chars > 0 and len(body) > max_chars:
        body = body[:max_chars].rstrip()
        body += "\n• …more details in the GitHub release"
    return "\n\n" + body


def main():
    env = parse_env(os.environ["SIGNAL_BOT_ENV"])
    signal_number = env.get("SIGNAL_NUMBER", "")
    group_id = next((item.strip() for item in env.get("TARGET_GROUP_IDS", "").split(",") if item.strip()), "")
    api_url = env.get("SIGNAL_API_URL", "http://localhost:8080").rstrip("/")
    if not signal_number or not group_id:
        print("warning: Signal notify skipped: missing SIGNAL_NUMBER or TARGET_GROUP_IDS", file=sys.stderr)
        return 0

    recipient = "group." + base64.b64encode(group_id.encode()).decode()
    version = os.environ["CYANIDE_VERSION"]
    tag = os.environ["CYANIDE_TAG"]
    release_url = os.environ["CYANIDE_RELEASE_URL"]
    notes = compact_notes(os.environ.get("CYANIDE_RELEASE_NOTES", ""))
    message = f"🍏 Cyanide {version} is out\n\nRelease notes + download:\n{release_url}{notes}"
    if os.environ.get("SIGNAL_RELEASE_NOTIFY_DRY_RUN") == "1":
        print(f"==> Signal dry run for {tag}: {len(message)} chars")
        return 0

    body = {
        "number": signal_number,
        "recipients": [recipient],
        "message": message,
        "text_mode": "normal",
    }
    request = urllib.request.Request(
        f"{api_url}/v2/send",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            response.read()
    except urllib.error.URLError as exc:
        print(f"warning: Signal release notification failed: {exc}", file=sys.stderr)
        return 0

    print(f"==> posted Signal release notification for {tag}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
