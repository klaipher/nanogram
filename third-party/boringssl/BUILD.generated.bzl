# Source lists for //third-party/boringssl, taken from upstream's pregenerated
# src/gen/sources.bzl (written by upstream's `go run ./util/pregenerate`).
# src/ is the klaipher/boringssl submodule (branch nanogram). Upstream paths are
# relative to its repository root, which is src/ here, so each list is
# re-exported with a "src/" prefix. Do not hand-edit file lists: move the
# submodule to the next upstream tag instead; no regeneration step is needed.

load(
    ":src/gen/sources.bzl",
    _bcm_internal_headers = "bcm_internal_headers",
    _bcm_sources = "bcm_sources",
    _bcm_sources_asm = "bcm_sources_asm",
    _bssl_internal_headers = "bssl_internal_headers",
    _bssl_sources = "bssl_sources",
    _crypto_headers = "crypto_headers",
    _crypto_internal_headers = "crypto_internal_headers",
    _crypto_sources = "crypto_sources",
    _crypto_sources_asm = "crypto_sources_asm",
    _ssl_headers = "ssl_headers",
    _ssl_internal_headers = "ssl_internal_headers",
    _ssl_sources = "ssl_sources",
)

def _src(files):
    return ["src/" + f for f in files]

bcm_internal_headers = _src(_bcm_internal_headers)
bcm_sources = _src(_bcm_sources)
bcm_sources_asm = _src(_bcm_sources_asm)
bssl_internal_headers = _src(_bssl_internal_headers)
bssl_sources = _src(_bssl_sources)
crypto_headers = _src(_crypto_headers)
crypto_internal_headers = _src(_crypto_internal_headers)
crypto_sources = _src(_crypto_sources)
crypto_sources_asm = _src(_crypto_sources_asm)
ssl_headers = _src(_ssl_headers)
ssl_internal_headers = _src(_ssl_internal_headers)
ssl_sources = _src(_ssl_sources)
