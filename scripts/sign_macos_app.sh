#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:?usage: sign_macos_app.sh <app-bundle> <bundle-id>}"
BUNDLE_ID="${2:?usage: sign_macos_app.sh <app-bundle> <bundle-id>}"
SIGNING_IDENTITY="${JOY_HARNESS_SIGNING_IDENTITY:-}"

# Prefer the SHA-1 hash over the common name. Duplicate certificates can share a
# label and make codesign fail with "ambiguous". Prefer Developer ID Application
# for local installs so Gatekeeper/XProtect is less likely to trash the app.
pick_identity_hash() {
  local label_prefix="$1"
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n "s/^ *[0-9][0-9]*) *\\([0-9A-Fa-f]\\{40\\}\\) *\"${label_prefix}[^\"]*\".*/\\1/p" \
    | head -n 1
}

if [[ -z "${SIGNING_IDENTITY}" ]]; then
  SIGNING_IDENTITY="$(pick_identity_hash "Developer ID Application:")"
fi
if [[ -z "${SIGNING_IDENTITY}" ]]; then
  SIGNING_IDENTITY="$(pick_identity_hash "Apple Development:")"
fi

identity_is_developer_id() {
  local identity="$1"
  if [[ "${identity}" == "Developer ID Application:"* ]]; then
    return 0
  fi
  security find-identity -v -p codesigning 2>/dev/null \
    | grep -Eq "^ *[0-9]+\\) *${identity} *\"Developer ID Application:"
}

if [[ -n "${SIGNING_IDENTITY}" && "${SIGNING_IDENTITY}" != "-" ]]; then
  echo "==> Signing ${APP_BUNDLE} with ${SIGNING_IDENTITY}"
  CODESIGN_ARGS=(
    --force
    --deep
    --sign "${SIGNING_IDENTITY}"
    --identifier "${BUNDLE_ID}"
  )
  if identity_is_developer_id "${SIGNING_IDENTITY}"; then
    CODESIGN_ARGS+=(--options runtime --timestamp)
  fi
  codesign "${CODESIGN_ARGS[@]}" "${APP_BUNDLE}"
else
  echo "==> Signing ${APP_BUNDLE} with a stable ad-hoc requirement"
  codesign --force --deep --sign - \
    --identifier "${BUNDLE_ID}" \
    --requirements "=designated => identifier \"${BUNDLE_ID}\"" \
    "${APP_BUNDLE}"
fi

codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
