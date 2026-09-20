#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:?usage: sign_macos_app.sh <app-bundle> <bundle-id>}"
BUNDLE_ID="${2:?usage: sign_macos_app.sh <app-bundle> <bundle-id>}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGNING_MODE="${3:-distribution}"
IDENTITY_FILE="${HOME}/.agent-deck/signing-identity"

if [[ -z "${JOY_HARNESS_SIGNING_IDENTITY:-}" && -f "${PROJECT_ROOT}/.env.local" ]]; then
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/.env.local"
fi

SIGNING_IDENTITY="${JOY_HARNESS_SIGNING_IDENTITY:-}"
if [[ "${SIGNING_MODE}" == "local" && -f "${IDENTITY_FILE}" ]]; then
  PINNED_IDENTITY="$(cat "${IDENTITY_FILE}")"
  if [[ -z "${PINNED_IDENTITY}" ]]; then
    echo "empty signing identity file: ${IDENTITY_FILE}" >&2
    exit 2
  fi
  if [[ -n "${SIGNING_IDENTITY}" && "${SIGNING_IDENTITY}" != "${PINNED_IDENTITY}" ]]; then
    echo "signing identity differs from ${IDENTITY_FILE}; refusing to change local app trust" >&2
    exit 2
  fi
  SIGNING_IDENTITY="${PINNED_IDENTITY}"
fi

# Prefer the SHA-1 hash over the common name. Duplicate certificates can share a
# label and make codesign fail with "ambiguous". Local builds pin a Developer
# ID identity so environment or keychain changes cannot silently change trust.
pick_identity_hash() {
  local label_prefix="$1"
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n "s/^ *[0-9][0-9]*) *\\([0-9A-Fa-f]\\{40\\}\\) *\"${label_prefix}[^\"]*\".*/\\1/p" \
    | head -n 1
}

if [[ -z "${SIGNING_IDENTITY}" ]]; then
  SIGNING_IDENTITY="$(pick_identity_hash "Developer ID Application:")"
fi
if [[ -z "${SIGNING_IDENTITY}" && "${SIGNING_MODE}" != "local" ]]; then
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

if [[ "${SIGNING_MODE}" == "local" ]]; then
  if ! identity_is_developer_id "${SIGNING_IDENTITY}"; then
    echo "local builds require a Developer ID Application identity; refusing to change app trust" >&2
    exit 2
  fi
fi

if [[ -n "${SIGNING_IDENTITY}" && "${SIGNING_IDENTITY}" != "-" ]]; then
  echo "==> Signing ${APP_BUNDLE} with ${SIGNING_IDENTITY}"
  # Nested drivers are signed first by build_microphone_driver.sh. Do not
  # recursively re-sign them with the parent bundle identifier.
  CODESIGN_ARGS=(
    --force
    --sign "${SIGNING_IDENTITY}"
    --identifier "${BUNDLE_ID}"
  )
  if identity_is_developer_id "${SIGNING_IDENTITY}"; then
    CODESIGN_ARGS+=(--options runtime --timestamp)
  fi
  codesign "${CODESIGN_ARGS[@]}" "${APP_BUNDLE}"
else
  echo "==> Signing ${APP_BUNDLE} with a stable ad-hoc requirement"
  codesign --force --sign - \
    --identifier "${BUNDLE_ID}" \
    --requirements "=designated => identifier \"${BUNDLE_ID}\"" \
    "${APP_BUNDLE}"
fi

codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
if [[ "${SIGNING_MODE}" == "local" && ! -f "${IDENTITY_FILE}" ]]; then
  mkdir -p "$(dirname "${IDENTITY_FILE}")"
  printf '%s\n' "${SIGNING_IDENTITY}" > "${IDENTITY_FILE}"
fi
