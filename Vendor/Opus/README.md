# Vendored Opus 1.5.2

Source: https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz

Release SHA-256: `65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1`

The archive was downloaded and its SHA-256 recorded on 2026-10-17. This hash
pins the reviewed source; it is not a claim of a separately verified signature.
`UPSTREAM_FILES.json` records the SHA-256 of every unmodified vendored upstream
file. `COPYING` contains the upstream BSD license; the same text is bundled in
JoyHarness's resources under `ThirdPartyLicenses/Opus-BSD.txt`.

`Package.swift` compiles a static C target from the portable sources listed in
upstream `OPUS_SOURCES`, `OPUS_SOURCES_FLOAT`, `CELT_SOURCES`, `SILK_SOURCES`, and
`SILK_SOURCES_FLOAT`. Headers are copied unchanged. This includes the codec's
portable encoder support to preserve its maintained source grouping, although
JoyHarness exposes only decoding. CPU-specific assembly/intrinsics and optional
neural codec extensions are disabled. The upstream default `ENABLE_HARDENING`
runtime checks remain enabled. Both arm64 and x86_64 use the same C code.
No Homebrew library, runtime `dlopen`, Python, download or binary framework is
needed to build or run the application.

The only local C additions are `JoyHarnessOpus.c` and
`public/JoyHarnessOpus.h`, a narrow 48 kHz mono decoder/reset/PLC API. Swift checks
packet length and frame format before decoding. The native decoder is owned by
one serial audio worker; it is not safe to call it concurrently.

To update: download an official release, verify and record its hash, copy the
above source groups and headers, regenerate the per-file manifest, retain its
license, and run fixed decoder/CRC tests plus both architecture builds. Do not
silently replace files or make the runtime locate a system codec.
