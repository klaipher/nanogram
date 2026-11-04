"""Privacy guards, checked on the source (no build). Nothing here may talk to Telegram about how the
app is used: channel read metrics, music listening, call routes and logs, time zone, analytics events.

    python3 -m unittest tools/dev/tests/test_privacy.py
"""
import os
import re
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..'))
SOURCE_DIRS = ['submodules', 'Telegram']
SKIP_DIRS = {'TelegramApi', 'Tests', 'build', '.git', 'third-party', 'node_modules'}


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding='utf-8') as f:
        return f.read()


def swift_sources():
    for base in SOURCE_DIRS:
        for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, base)):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.endswith('Tests')]
            for name in filenames:
                if name.endswith('.swift'):
                    yield os.path.join(dirpath, name)


def uses(pattern):
    regex = re.compile(pattern)
    found = []
    for path in swift_sources():
        with open(path, encoding='utf-8', errors='replace') as f:
            for number, line in enumerate(f, 1):
                if regex.search(line) and not line.lstrip().startswith('//'):
                    found.append('%s:%d' % (os.path.relpath(path, ROOT), number))
    return found


def function_body(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError('unbalanced ' + signature)


class PrivacyTests(unittest.TestCase):
    def test_no_request_sends_channel_read_metrics(self):
        self.assertEqual(uses(r'functions\.messages\.reportReadMetrics'), [])

    def test_report_peer_read_metrics_sends_nothing(self):
        source = read('submodules/TelegramCore/Sources/TelegramEngine/Messages/TelegramEngineMessages.swift')
        body = function_body(source, 'public func reportPeerReadMetrics(')
        self.assertEqual(body.strip(), 'return .complete()')

    def test_read_metrics_trackers_are_gone(self):
        self.assertEqual(uses(r'\bMessageReadMetricsTracker\b'), [])
        self.assertFalse(os.path.exists(os.path.join(ROOT, 'submodules/TelegramCore/Sources/Utils/MessageReadMetricsTracker.swift')))

    def test_no_request_sends_music_listening(self):
        self.assertEqual(uses(r'functions\.messages\.reportMusicListen'), [])

    def test_report_music_listened_sends_nothing(self):
        source = read('submodules/TelegramCore/Sources/TelegramEngine/Messages/TelegramEngineMessages.swift')
        body = function_body(source, 'public func reportMusicListened(')
        self.assertEqual(body.strip(), 'return .complete()')

    def test_music_listen_tracker_is_gone(self):
        self.assertEqual(uses(r'\bMusicListenTracker\b'), [])

    def test_no_request_uploads_call_debug_or_logs(self):
        self.assertEqual(uses(r'functions\.phone\.saveCallDebug'), [])
        self.assertEqual(uses(r'functions\.phone\.saveCallLog'), [])

    def test_call_contexts_do_not_upload_logs(self):
        self.assertEqual(uses(r'\.saveCallDebugLog\(|\.saveCompleteCallDebugLog\('), [])

    def test_call_log_functions_never_touch_the_network(self):
        source = read('submodules/TelegramCore/Sources/TelegramEngine/Calls/RateCall.swift')
        self.assertNotIn('network.request', function_body(source, 'func _internal_saveCallDebugLog'))
        self.assertNotIn('multipartUpload', function_body(source, 'func _internal_saveCompleteCallDebugLog'))

    def test_time_zone_is_not_sent(self):
        self.assertNotIn('tz_offset', read('submodules/BuildConfig/Sources/BuildConfig.m'))

    def test_connection_fingerprint_is_trimmed(self):
        source = read('submodules/MtProtoKit/Sources/MTApiEnvironment.m')
        self.assertIn('majorSystemVersion:', source)
        self.assertIn('languageCodeWithoutRegion:', source)
        self.assertNotIn('[[NSLocale preferredLanguages] objectAtIndex:0]', source)
        self.assertNotIn('hw.model', source)
        self.assertNotRegex(source, r'return @"iPhone \d')

    def test_app_log_events_are_filtered_where_they_are_sent(self):
        sender = read('submodules/TelegramCore/Sources/State/ManagedSynchronizeAppLogEventsOperations.swift')
        self.assertIn('appLogEventMayLeaveDevice(type: type)', sender)
        queue = read('submodules/TelegramCore/Sources/State/SynchronizeAppLogEventsOperation.swift')
        self.assertRegex(queue, r'appLogEventTypesAllowedToLeaveDevice: Set<String> = \[\]')

    def test_release_builds_never_record_network_telemetry(self):
        source = read('submodules/TelegramCore/Sources/Network/NetworkTelemetry.swift')
        body = function_body(source, 'func networkTelemetryShouldRecord(')
        self.assertNotIn('configuration.isEnabled', body)
        self.assertIn('#else\nlet networkTelemetryAlwaysRecords = false', source)


if __name__ == '__main__':
    unittest.main()
