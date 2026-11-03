#!/usr/bin/env python3
"""Tests for tools/dev/tf_notes.py against a fake App Store Connect and a fake clock; no network.

  python3 tools/dev/tests/test_tf_notes.py
"""
import contextlib
import importlib.util
import io
import json
import socket
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parent.parent / "tf_notes.py"
spec = importlib.util.spec_from_file_location("tf_notes", SCRIPT)
tf_notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tf_notes)

BUILD = "202611031200"
BUILD_ID = "build-1"


class FakeClock:
    def __init__(self):
        self.now = 1000.0
        self.sleeps = []

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds


class FakeResponse:
    def __init__(self, body, raw=None):
        self.body = raw if raw is not None else (json.dumps(body).encode() if body is not None else b"")

    def read(self):
        return self.body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeAppStoreConnect:
    """Answers the four requests tf_notes.py makes. `failures` maps a request kind ("builds",
    "get-localizations", "post", "patch") to a list of exceptions raised before it answers (or
    responses returned instead of the answer)."""

    def __init__(self, states):
        self.states = list(states)
        self.localizations = []
        self.failures = {}
        self.requests = []

    def fail(self, kind, *errors):
        self.failures.setdefault(kind, []).extend(errors)

    def urlopen(self, request, timeout=None):
        method, url = request.get_method(), request.full_url
        if url.startswith(tf_notes.ASC + "/v1/builds?"):
            kind = "builds"
        elif url.endswith("/betaBuildLocalizations") and method == "GET":
            kind = "get-localizations"
        elif method == "POST":
            kind = "post"
        elif method == "PATCH":
            kind = "patch"
        else:
            raise AssertionError(f"unexpected request {method} {url}")
        self.requests.append(kind)
        if kind == "post":
            # The server may have created it even when the client never sees the answer.
            body = json.loads(request.data)
            self.localizations.append({"id": f"loc-{len(self.localizations)}", "attributes": dict(body["data"]["attributes"])})
        if self.failures.get(kind):
            failure = self.failures[kind].pop(0)
            if isinstance(failure, FakeResponse):
                return failure
            raise failure
        if kind == "builds":
            state = self.states.pop(0) if len(self.states) > 1 else self.states[0]
            return FakeResponse({"data": [] if state is None else [{"id": BUILD_ID, "attributes": {"processingState": state}}]})
        if kind == "get-localizations":
            return FakeResponse({"data": self.localizations})
        if kind == "patch":
            body = json.loads(request.data)
            for localization in self.localizations:
                if localization["id"] == body["data"]["id"]:
                    localization["attributes"].update(body["data"]["attributes"])
            return FakeResponse(None)
        return FakeResponse({"data": self.localizations[-1]})


def http_error(code, retry_after=None):
    headers = {"Retry-After": str(retry_after)} if retry_after is not None else {}
    return urllib.error.HTTPError("https://api.appstoreconnect.apple.com", code, "error", headers, io.BytesIO(b"{}"))


class UnreadableBody:
    """An error response whose body times out while it is read."""
    def read(self, *args):
        raise socket.timeout("timed out")

    def close(self):
        pass


def http_error_with_unreadable_body(code):
    return urllib.error.HTTPError("https://api.appstoreconnect.apple.com", code, "error", {}, UnreadableBody())


class TfNotesTests(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        self.notes = Path(tempfile.mkdtemp()) / "notes.txt"
        self.notes.write_text("Fixes.\n")
        for patcher in (mock.patch.object(tf_notes, "jwt", lambda: "token"),
                        mock.patch.object(tf_notes.time, "monotonic", self.clock.monotonic),
                        mock.patch.object(tf_notes.time, "sleep", self.clock.sleep)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def run_main(self, server, wait_minutes=45):
        argv = ["tf_notes.py", "IOS", BUILD, str(self.notes), "--wait", str(wait_minutes)]
        with mock.patch.object(tf_notes.urllib.request, "urlopen", server.urlopen), \
                mock.patch.object(sys, "argv", argv), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            tf_notes.main()
        return out.getvalue()

    def notes_set(self, server):
        return [l["attributes"].get("whatsNew") for l in server.localizations if l["attributes"].get("locale") == "en-US"]

    def test_rate_limit_while_waiting_is_retried(self):
        server = FakeAppStoreConnect(["PROCESSING", "VALID"])
        server.fail("builds", http_error(429), http_error(429))
        self.run_main(server)
        self.assertEqual(self.notes_set(server), ["Fixes."])

    def test_network_timeout_while_waiting_is_retried(self):
        server = FakeAppStoreConnect(["VALID"])
        server.fail("builds", socket.timeout("timed out"), TimeoutError("timed out"),
                    urllib.error.URLError(socket.timeout("timed out")), ConnectionResetError("reset"))
        self.run_main(server)
        self.assertEqual(self.notes_set(server), ["Fixes."])

    def test_retries_back_off(self):
        server = FakeAppStoreConnect(["VALID"])
        server.fail("builds", *[http_error(429) for _ in range(4)])
        self.run_main(server)
        self.assertEqual(len(self.clock.sleeps), 4)
        self.assertEqual(self.clock.sleeps, sorted(self.clock.sleeps), "each retry waits at least as long as the last")
        self.assertGreater(self.clock.sleeps[-1], self.clock.sleeps[0])
        self.assertLessEqual(max(self.clock.sleeps), tf_notes.POLL_SECONDS)

    def test_retry_after_is_honoured(self):
        server = FakeAppStoreConnect(["VALID"])
        server.fail("builds", http_error(429, retry_after=17))
        self.run_main(server)
        self.assertEqual(self.clock.sleeps, [17])

    def test_rate_limit_when_setting_the_notes_is_retried(self):
        server = FakeAppStoreConnect(["VALID"])
        server.fail("get-localizations", http_error(429))
        server.fail("post", http_error(429))
        self.run_main(server)
        self.assertEqual(self.notes_set(server), ["Fixes."])

    def test_a_create_that_timed_out_is_not_duplicated(self):
        server = FakeAppStoreConnect(["VALID"])
        server.fail("post", socket.timeout("timed out"))
        self.run_main(server)
        self.assertEqual(self.notes_set(server), ["Fixes."], "the retry updates the localization the lost POST created")
        self.assertEqual(server.requests.count("post"), 1)

    def test_gives_up_at_the_end_of_the_wait_window(self):
        server = FakeAppStoreConnect(["PROCESSING"])
        server.fail("builds", *[http_error(429) for _ in range(1000)])
        with self.assertRaises(SystemExit) as raised:
            self.run_main(server, wait_minutes=10)
        self.assertIn("429", str(raised.exception.code))
        self.assertLessEqual(self.clock.now - 1000.0, 10 * 60, "never waits past the window")

    def test_client_errors_are_not_retried(self):
        server = FakeAppStoreConnect(["VALID"])
        server.fail("builds", http_error(401))
        with self.assertRaises(SystemExit) as raised:
            self.run_main(server)
        self.assertIn("401", str(raised.exception.code))
        self.assertEqual(server.requests, ["builds"])
        self.assertEqual(self.clock.sleeps, [])


    # Apple rejected the upload: a distinct exit code, so tg testflight can say a new build is needed.
    def test_failed_processing_exits_with_its_own_code(self):
        for state in ("FAILED", "INVALID"):
            server = FakeAppStoreConnect(["PROCESSING", state])
            with self.assertRaises(SystemExit) as raised, contextlib.redirect_stderr(io.StringIO()) as err:
                self.run_main(server)
            self.assertEqual(raised.exception.code, tf_notes.EXIT_BUILD_REJECTED)
            self.assertEqual(tf_notes.EXIT_BUILD_REJECTED, 4)
            self.assertIn(state, err.getvalue())
            self.assertEqual(self.notes_set(server), [])

    # A 200 whose body is cut off or not JSON (a proxy's page) is a passing failure.
    def test_a_garbled_answer_is_retried(self):
        server = FakeAppStoreConnect(["VALID"])
        server.fail("builds", FakeResponse(None, raw=b"<html>busy</html>"), FakeResponse(None, raw=b'{"data": ['))
        self.run_main(server)
        self.assertEqual(self.notes_set(server), ["Fixes."])

    def test_a_timeout_reading_an_error_body_is_retried(self):
        server = FakeAppStoreConnect(["VALID"])
        server.fail("builds", http_error_with_unreadable_body(503))
        server.fail("post", http_error_with_unreadable_body(500))
        self.run_main(server)
        self.assertEqual(self.notes_set(server), ["Fixes."])


if __name__ == "__main__":
    unittest.main()
