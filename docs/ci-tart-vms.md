# CI builds in tart VMs

### CI builds in tart VMs (and why every download needs a checksum)

GitLab CI (`.gitlab-ci.yml`) builds, uploads to TestFlight and verifies in tart VMs on the runner host:
`Make.py vm-build` / `vm-deploy-testflight` / `vm-ipa-diff` (`build-system/Make/TartBuild.py`), each in an ephemeral
clone of `macos-<macos>-xcode-<xcode>` from `versions.json` (uploads use `deploy_xcode`). One VM runs per host
(an flock at `~/.telegram-build/vm-build.lock`); CI passes `--waitForLock` so a second job queues instead of failing.
gitlab-runner runs as a launchd service whose PATH has no Homebrew, so `tart` is resolved via `TART_PATH`, PATH, then
the Homebrew locations. The bazel cache is bazel-remote on the runner host (`TELEGRAM_BAZEL_CACHE_HOST`); the guest
reaches it through tart's NAT at the host's LAN address or the gateway (`grpc://@auto:9092`).

**Every external download must carry a checksum.** Make.py points both `--remote_cache` and
`--experimental_remote_downloader` at bazel-remote, so bazel asks bazel-remote to fetch each archive and waits for the
whole download under the 60s `--remote_timeout`. bazel-remote serves an archive from its store only when the request
names its sha256; without one it re-downloads it from the internet on every build (the repository cache needs the
checksum too, and each ephemeral VM starts with an empty one). On the runner's link (~300-400 KB/s from
static.rust-lang.org) a large archive misses the deadline: the build log fills with
`Remote Cache: DEADLINE_EXCEEDED … remote_addr=…:9092`, the guest sits idle, and after the retries
`--experimental_remote_downloader_local_fallback` (`.bazelrc`) downloads it again inside the VM. It reads like the VM
cannot reach the cache; it can (`curl http://<cache>:8080/status` from the guest answers in milliseconds), and the
tell is bazel-remote holding an outbound connection to the archive's host. This happened with the Rust toolchain
when rules_rust did not yet know the pinned Rust version's checksums. rules_rust 0.75.0's `known_shas.bzl` covers
the pinned 1.99.1. **Bumping Rust past what rules_rust knows means adding `rust.toolchain(sha256s = …)`** (each
archive's checksum is at `static.rust-lang.org/dist/<archive>.sha256`).
