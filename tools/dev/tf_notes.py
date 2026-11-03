#!/usr/bin/env python3
"""Set a TestFlight build's "What to Test" notes (en-US) through the App Store Connect API.

  tf_notes.py IOS|MAC_OS <build number> <notes file> [--dry-run] [--wait MINUTES]
  tf_notes.py --check <notes file>

<build number> is the build's CFBundleVersion. --wait polls (once a minute, for at most MINUTES)
until App Store Connect has processed the upload, then sets the notes; without it the build must
already be there. With --wait, rate limiting (HTTP 429), server errors and network failures or
timeouts are retried with backoff (5 s doubling to 60 s, or the server's Retry-After) until the
window ends (a garbled answer or an error body that times out counts as a network failure);
setting the notes gets at least 2 more minutes of retries once the build is ready. When App Store
Connect rejects the build (processing ended FAILED or INVALID) it exits 4: no notes can be set,
upload a new build. --dry-run prints the build and its current notes and changes nothing. --check
only validates the notes file (non-empty, at most 4000 characters) and makes no network call;
`tg testflight` runs it before building.

Credentials: the team API key in ~/.config/telegram-ios/asc (asc.json with key_id and issuer_id,
next to AuthKey_<key_id>.p8), the same key tools/dev/device_signing.py uploads with. Nothing
secret is in this file. TG_ASC_APP_ID overrides the App Store Connect app id.
"""
import argparse
import base64
import http.client
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
# Backoff for a failed request inside the wait window: doubles from here up to POLL_SECONDS.
RETRY_FIRST_SECONDS = 5
# Retries left for setting the notes when the build became ready at the very end of the window.
SET_NOTES_MIN_RETRY_SECONDS = 120
# Exit code when App Store Connect rejected the build: tg testflight then asks for a new upload.
EXIT_BUILD_REJECTED = 4


class ApiError(Exception):
    def __init__(self, message, status=None, retry_after=None):
        super().__init__(message)
        self.status = status
        self.retry_after = retry_after

    @property
    def transient(self):
        """No answer (network failure, timeout), rate limited or a server error: worth retrying.
        Any other client error will not go away."""
        return self.status is None or self.status == 429 or self.status >= 500


def retry_after_seconds(headers):
    value = headers.get("Retry-After") if headers is not None else None
    try:
        return max(0.0, float(value)) if value is not None else None
    except ValueError:
        return None  # The HTTP-date form: use our own backoff.


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
    what = f"{method} {path.split('?')[0]}"
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
        try:
            return json.loads(raw) if raw else {}
        except ValueError as e:
            # Cut off, or not App Store Connect's (a proxy's page): like a lost answer.
            raise ApiError(f"{what}: unreadable answer ({e}): {raw[:200]!r}")
    except urllib.error.HTTPError as e:
        try:
            body = e.read().decode(errors="replace")[:400]
        except (OSError, http.client.HTTPException) as read_error:
            # The error's body timed out or broke off: no answer to judge, so retry.
            raise ApiError(f"{what}: HTTP {e.code}, body unreadable: {read_error or type(read_error).__name__}")
        raise ApiError(f"{what}: HTTP {e.code}: {body}", e.code, retry_after_seconds(e.headers))
    except urllib.error.URLError as e:
        raise ApiError(f"{what}: {e.reason}")
    except (OSError, http.client.HTTPException) as e:
        # A timeout while reading the answer, a reset connection, a truncated response.
        raise ApiError(f"{what}: {e or type(e).__name__}")


def with_retries(what, f, deadline):
    """f(), retrying transient ApiErrors with backoff until `deadline` (time.monotonic()); no
    retries without a deadline. f must be safe to repeat."""
    delay = RETRY_FIRST_SECONDS
    while True:
        try:
            return f()
        except ApiError as e:
            if deadline is None or not e.transient:
                raise
            wait = e.retry_after if e.retry_after is not None else delay
            remaining = deadline - time.monotonic()
            if wait > remaining:
                raise ApiError(f"{e} (gave up {what}: the wait window ends in {max(0, int(remaining))} s)", e.status)
            print(f"  {e}; retrying {what} in {wait:g} s", flush=True)
            time.sleep(wait)
            delay = min(delay * 2, POLL_SECONDS)


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


def wait_for_processed_build(platform, number, deadline, minutes):
    last_state = None
    while True:
        # A 45-minute poll should outlive a passing outage or rate limiting.
        build = with_retries("the build lookup", lambda: find_build(platform, number), deadline)
        state = build["attributes"].get("processingState") if build else "NOT_FOUND"
        if state != last_state:
            print(f"  build {number} ({platform}): {state}", flush=True)
            last_state = state
        if state == "VALID":
            return build
        if state in ("FAILED", "INVALID"):
            print(f"build {number} ({platform}) processing ended {state}: App Store Connect rejected it; no notes set",
                  file=sys.stderr)
            sys.exit(EXIT_BUILD_REJECTED)
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
            deadline = time.monotonic() + args.wait * 60
            build = wait_for_processed_build(args.platform, args.build, deadline, args.wait)
            notes_deadline = max(deadline, time.monotonic() + SET_NOTES_MIN_RETRY_SECONDS)
        else:
            build = find_build(args.platform, args.build)
            if build is None:
                sys.exit(f"build {args.build} ({args.platform}) not found yet: still processing or not uploaded")
            notes_deadline = None
        print(f"build {args.build}: id {build['id']}, processingState {build['attributes'].get('processingState')}")
        with_retries("setting the notes", lambda: set_notes(build["id"], notes, args.dry_run), notes_deadline)
    except ApiError as e:
        sys.exit(str(e))


def set_notes(build_id, notes, dry_run):
    """Reads the build's en-US localization and creates or updates it. Safe to repeat: a POST
    whose answer was lost created the localization, and the repeat updates it."""
    locs = call("GET", f"/v1/builds/{build_id}/betaBuildLocalizations")["data"]
    existing = next((l for l in locs if l["attributes"].get("locale") == "en-US"), None)
    if existing:
        print("current notes:", repr(existing["attributes"].get("whatsNew")))
    if dry_run:
        return
    if existing:
        call("PATCH", f"/v1/betaBuildLocalizations/{existing['id']}",
             {"data": {"type": "betaBuildLocalizations", "id": existing["id"], "attributes": {"whatsNew": notes}}})
    else:
        call("POST", "/v1/betaBuildLocalizations",
             {"data": {"type": "betaBuildLocalizations", "attributes": {"locale": "en-US", "whatsNew": notes},
                       "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
    check = call("GET", f"/v1/builds/{build_id}/betaBuildLocalizations")["data"]
    print("notes now:", [l["attributes"].get("whatsNew") for l in check if l["attributes"].get("locale") == "en-US"])


if __name__ == "__main__":
    main()
