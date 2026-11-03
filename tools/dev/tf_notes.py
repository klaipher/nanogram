#!/usr/bin/env python3
"""Set a TestFlight build's "What to Test" notes (en-US) through the App Store Connect API.

  tf_notes.py IOS|MAC_OS <build number> <notes file> [--dry-run] [--wait MINUTES]
  tf_notes.py --check <notes file>

<build number> is the build's CFBundleVersion. --wait polls (once a minute, for at most MINUTES)
until App Store Connect has processed the upload, then sets the notes; without it the build must
already be there. --dry-run prints the build and its current notes and changes nothing. --check
only validates the notes file (non-empty, at most 4000 characters) and makes no network call;
`tg testflight` runs it before building.

Credentials: the team API key in ~/.config/telegram-ios/asc (asc.json with key_id and issuer_id,
next to AuthKey_<key_id>.p8), the same key tools/dev/device_signing.py uploads with. Nothing
secret is in this file. TG_ASC_APP_ID overrides the App Store Connect app id.
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ASC = "https://api.appstoreconnect.apple.com"
KEY_DIR = Path.home() / ".config/telegram-ios/asc"
# Nanogram's App Store Connect app record (an identifier, not a credential).
APP_ID = os.environ.get("TG_ASC_APP_ID", "6829268176")
# App Store Connect's limit for whatsNew.
MAX_NOTES_LENGTH = 4000
POLL_SECONDS = 60


class ApiError(Exception):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


def jwt() -> str:
    cfg = json.loads((KEY_DIR / "asc.json").read_text())
    key_path = KEY_DIR / f"AuthKey_{cfg['key_id']}.p8"

    def b64(data: bytes) -> str:
        return base64.urlsafe_b64encode(data).rstrip(b"=").decode()
    now = int(time.time())
    signing_input = (b64(json.dumps({"alg": "ES256", "kid": cfg["key_id"], "typ": "JWT"}).encode()) + "." +
                     b64(json.dumps({"iss": cfg["issuer_id"], "iat": now, "exp": now + 600,
                                     "aud": "appstoreconnect-v1"}).encode()))
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key_path)], input=signing_input.encode(),
                         capture_output=True, check=True).stdout
    # openssl signs ES256 as a DER SEQUENCE of two INTEGERs; JWS wants r || s, 32 bytes each.
    offset = 4 if der[1] & 0x80 else 2

    def integer(at):
        length = der[at + 1]
        return der[at + 2:at + 2 + length].lstrip(b"\0").rjust(32, b"\0"), at + 2 + length
    r, offset = integer(offset)
    s, _ = integer(offset)
    return signing_input + "." + b64(r + s)


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(ASC + path, data=data, method=method,
                                 headers={"Authorization": "Bearer " + jwt(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raise ApiError(f"{method} {path.split('?')[0]}: HTTP {e.code}: {e.read().decode()[:400]}", e.code)
    except urllib.error.URLError as e:
        raise ApiError(f"{method} {path.split('?')[0]}: {e.reason}")


def read_notes(path) -> str:
    try:
        notes = Path(path).read_text().strip()
    except OSError as e:
        sys.exit(f"cannot read notes file {path}: {e.strerror}")
    if not notes:
        sys.exit(f"notes file {path} is empty: every TestFlight build needs What to Test notes")
    if len(notes) > MAX_NOTES_LENGTH:
        sys.exit(f"notes file {path} has {len(notes)} characters; App Store Connect allows {MAX_NOTES_LENGTH}")
    return notes


def find_build(platform, number):
    builds = call("GET", f"/v1/builds?filter%5Bapp%5D={APP_ID}&filter%5Bversion%5D={number}"
                         f"&filter%5BpreReleaseVersion.platform%5D={platform}&limit=5")["data"]
    return builds[0] if builds else None


def wait_for_processed_build(platform, number, minutes):
    deadline = time.monotonic() + minutes * 60
    last_state = None
    while True:
        try:
            build = find_build(platform, number)
        except ApiError as e:
            # A 45-minute poll should outlive a passing outage; a client error will not go away.
            if e.status is not None and e.status < 500:
                raise
            print(f"  {e}; retrying", flush=True)
            build = None
        state = build["attributes"].get("processingState") if build else "NOT_FOUND"
        if state != last_state:
            print(f"  build {number} ({platform}): {state}", flush=True)
            last_state = state
        if state == "VALID":
            return build
        if state in ("FAILED", "INVALID"):
            sys.exit(f"build {number} ({platform}) processing ended {state}; no notes set")
        if time.monotonic() >= deadline:
            sys.exit(f"build {number} ({platform}) not processed after {minutes} min (last state {state})")
        time.sleep(POLL_SECONDS)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("platform", nargs="?", choices=["IOS", "MAC_OS"])
    parser.add_argument("build", nargs="?", help="CFBundleVersion of the uploaded build")
    parser.add_argument("notes", nargs="?", help="text file with the What to Test notes")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--wait", type=float, metavar="MINUTES", help="wait until the build has processed")
    parser.add_argument("--check", metavar="NOTES", help="only validate a notes file")
    args = parser.parse_args()

    if args.check is not None:
        if args.platform or args.build or args.notes:
            parser.error("--check takes only the notes file")
        notes = read_notes(args.check)
        print(f"notes ok: {len(notes)} characters")
        return
    if not (args.platform and args.build and args.notes):
        parser.error("needs IOS|MAC_OS <build number> <notes file>")

    notes = read_notes(args.notes)
    try:
        if args.wait is not None:
            build = wait_for_processed_build(args.platform, args.build, args.wait)
        else:
            build = find_build(args.platform, args.build)
            if build is None:
                sys.exit(f"build {args.build} ({args.platform}) not found yet: still processing or not uploaded")
        print(f"build {args.build}: id {build['id']}, processingState {build['attributes'].get('processingState')}")
        locs = call("GET", f"/v1/builds/{build['id']}/betaBuildLocalizations")["data"]
        existing = next((l for l in locs if l["attributes"].get("locale") == "en-US"), None)
        if existing:
            print("current notes:", repr(existing["attributes"].get("whatsNew")))
        if args.dry_run:
            return
        if existing:
            call("PATCH", f"/v1/betaBuildLocalizations/{existing['id']}",
                 {"data": {"type": "betaBuildLocalizations", "id": existing["id"], "attributes": {"whatsNew": notes}}})
        else:
            call("POST", "/v1/betaBuildLocalizations",
                 {"data": {"type": "betaBuildLocalizations", "attributes": {"locale": "en-US", "whatsNew": notes},
                           "relationships": {"build": {"data": {"type": "builds", "id": build["id"]}}}}})
        check = call("GET", f"/v1/builds/{build['id']}/betaBuildLocalizations")["data"]
        print("notes now:", [l["attributes"].get("whatsNew") for l in check if l["attributes"].get("locale") == "en-US"])
    except ApiError as e:
        sys.exit(str(e))


if __name__ == "__main__":
    main()
