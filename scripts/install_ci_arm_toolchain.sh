#!/usr/bin/env bash
set -euo pipefail

# Pin the complete Newlib toolchain instead of relying on stale Homebrew API
# metadata. Versions and SHA-256 values come from Homebrew/homebrew-cask commit
# 101a71f78bc68d6a258ee68194c75f3afc4e9587 (2026-10-14 checksum correction).
if [[ "${GITHUB_ACTIONS:-}" != true || -z "${RUNNER_TEMP:-}" || -z "${GITHUB_PATH:-}" ]]; then
  echo "This installer is only for disposable GitHub Actions runners." >&2
  exit 2
fi
case "$(uname -m)" in
  arm64)
    VERSION=15.3.rel2
    ARCH=arm64
    SHA256=779972fa545f738bfbba2ff0ae44d5ad7510b00cfb414702974844ba625412f3
    ;;
  x86_64)
    VERSION=14.2.rel1
    ARCH=x86_64
    SHA256=5d2e9ee4e73350bda79accc69fcd5ee59ccb902804a3f81a01d4c543b1ad7de7
    ;;
  *) echo "Unsupported runner architecture" >&2; exit 2 ;;
esac
NAME="arm-gnu-toolchain-${VERSION}-darwin-${ARCH}-arm-none-eabi.pkg"
PACKAGE="${RUNNER_TEMP}/${NAME}"
curl --fail --location --retry 3 \
  "https://gitlab.arm.com/api/v4/projects/tooling%2Fgnu-toolchains-for-arm/packages/generic/gnu-toolchain/${VERSION}/${NAME}" \
  --output "${PACKAGE}"
printf '%s  %s\n' "${SHA256}" "${PACKAGE}" | shasum -a 256 -c -
sudo /usr/sbin/installer -pkg "${PACKAGE}" -target /
TOOLCHAIN="/Applications/ArmGNUToolchain/${VERSION}/arm-none-eabi/bin"
"${TOOLCHAIN}/arm-none-eabi-gcc" --version
test -f "$("${TOOLCHAIN}/arm-none-eabi-gcc" -print-file-name=nosys.specs)"
printf '%s\n' "${TOOLCHAIN}" >> "${GITHUB_PATH}"
