"""Opt-in voice-message enhancement (Opus OSCE): the guards that keep it off everything but playback.

Reads repository text only; nothing is built. The libopus link-map guard for the built app is
shared/opus/check-link-map.sh (nanogram-deps), run on the TelegramUIFramework link map.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
WATCH = ROOT / "Telegram/WatchApp"


def read(rel):
    return (ROOT / rel).read_text(errors="replace")


class OsceBuildTests(unittest.TestCase):
    def test_opus_genrule_uses_the_shared_options_and_the_pinned_models(self):
        build = read("third-party/opus/BUILD")
        self.assertIn("//shared/opus:opus-options.sh", build)
        self.assertIn("//shared/opus:fetch-models.sh", build)
        self.assertIn("@opus_models_tar_gz//file", build)
        self.assertIn("fetch-models.sh", build)
        self.assertFalse((ROOT / "third-party/opus/opus-cmake-args.sh").exists())

    def test_models_are_pinned_in_module_bazel(self):
        module = read("MODULE.bazel")
        self.assertRegex(module, r'name = "opus_models_tar_gz",\s*sha256 = "a5177ec6fb7d15058e99e57029746100121f68e4890b1467d4094aa336b6013e"')
        shared = ROOT / "shared/opus/opus-options.sh"
        if shared.is_file():
            self.assertIn("a5177ec6fb7d15058e99e57029746100121f68e4890b1467d4094aa336b6013e", shared.read_text())

    def test_build_script_appends_osce_flags_to_the_release_flags_only(self):
        script = read("third-party/opus/build-opus-bazel.sh")
        self.assertIn("opus-options.sh", script)
        self.assertIn("$OPUS_OSCE_ARGS", script)
        self.assertIn("${OPUS_OSCE_C_FLAGS}", script)
        self.assertNotRegex(script, r"-DCMAKE_C_FLAGS=")
        self.assertEqual(len(re.findall(r'-DCMAKE_C_FLAGS_RELEASE="\$\{RELEASE_CFLAGS\}"', script)), 2)

    def test_models_never_go_into_the_submodule(self):
        script = read("third-party/opus/BUILD")
        self.assertIn('rm -rf "$$BUILD_DIR/opus/.git"', script)
        self.assertIn('fetch-models.sh" --archive', script)
        self.assertIn('"$$BUILD_DIR/opus"', script)


class WatchStaysStockTests(unittest.TestCase):
    def test_watch_libopus_config_has_no_osce_or_deep_plc(self):
        for config in WATCH.rglob("config.h"):
            if "COpus" in config.parts:
                text = config.read_text()
                self.assertNotIn("ENABLE_OSCE", text, config)
                self.assertNotIn("ENABLE_DEEP_PLC", text, config)
                self.assertNotIn("ENABLE_OSCE_BWE", text, config)

    def test_watch_has_no_dnn_sources(self):
        for copus in WATCH.rglob("COpus"):
            self.assertFalse((copus / "libopus/dnn").exists(), copus)

    def test_watch_does_not_reference_the_models_or_the_shared_opus_build(self):
        needles = ["opus_models", "shared/opus", "//third-party/opus", "OPUS_OSCE", "osce_complexity", "OpusSpeechEnhancement"]
        for path in WATCH.rglob("*"):
            if not path.is_file() or path.is_symlink() or path.suffix in {".png", ".jpg", ".pdf", ".a", ".o", ".car", ".strings"}:
                continue
            text = path.read_text(errors="ignore")
            for needle in needles:
                self.assertNotIn(needle, text, f"{path} mentions {needle}")


class PlaybackOnlyTests(unittest.TestCase):
    def test_only_playback_sources_apply_the_enhancement(self):
        users = sorted(str(path.relative_to(ROOT)) for path in (ROOT / "submodules").rglob("*.swift")
                       if "applyIfPlayback" in path.read_text(errors="ignore") or "setOpusDecoderComplexity" in path.read_text(errors="ignore"))
        self.assertEqual(users, [
            "submodules/MediaPlayer/Sources/FFMpegFileReader.swift",
            "submodules/MediaPlayer/Sources/FFMpegMediaFrameSourceContext.swift",
            "submodules/MediaPlayer/Sources/OpusSpeechEnhancement.swift",
            "submodules/MediaPlayer/Sources/SoftwareVideoSource.swift",
        ])

    def test_software_audio_source_passes_isplayback(self):
        text = read("submodules/MediaPlayer/Sources/SoftwareVideoSource.swift")
        self.assertIn("OpusSpeechEnhancement.applyIfPlayback(to: codecContext, isPlayback: isPlayback)", text)
        reader = read("submodules/MediaPlayer/Sources/MediaDataReader.swift")
        self.assertIn("SoftwareAudioSource(path: filePath, ignoreEditList: ignoreEditList, isPlayback: true)", reader)

    def test_transcription_conversion_and_the_notification_extension_do_not_touch_it(self):
        for rel in ["submodules/Media/ConvertOpusToAAC/Sources/ConvertOpusToAAC.swift"]:
            self.assertNotIn("OpusSpeechEnhancement", read(rel))
        convert = read("submodules/Media/ConvertOpusToAAC/Sources/ConvertOpusToAAC.swift")
        self.assertIn("SoftwareAudioSource(path: sourcePath)", convert)
        for path in (ROOT / "Telegram").glob("NotificationService*/**/*.swift"):
            self.assertNotIn("OpusSpeechEnhancement", path.read_text(errors="ignore"), path)

    def test_the_setting_is_mirrored_from_the_shared_context_and_defaults_off(self):
        context = read("submodules/TelegramUI/Sources/SharedAccountContext.swift")
        self.assertIn("OpusSpeechEnhancement.isEnabled = settings.voiceEnhancement", context)
        settings = read("submodules/TelegramUIPreferences/Sources/NanogramFeaturesSettings.swift")
        self.assertIn("onDeviceTranslation: false, voiceEnhancement: false)", settings)


if __name__ == "__main__":
    unittest.main()
