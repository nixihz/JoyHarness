#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:?usage: sign_macos_app.sh <app-bundle> <bundle-id>}"
BUNDLE_ID="${2:?usage: sign_macos_app.sh <app-bundle> <bundle-id>}"
SIGNING_IDENTITY="${JOY_HARNESS_SIGNING_IDENTITY:-}"

if [[ -z "${SIGNING_IDENTITY}" ]]; then
  while IFS= read -r identity; do
    SIGNING_IDENTITY="${identity}"
    break
  done < <(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Apple Development:[^"]*\)"/\1/p'
  )
fi

if [[ -n "${SIGNING_IDENTITY}" && "${SIGNING_IDENTITY}" != "-" ]]; then
  echo "==> Signing ${APP_BUNDLE} with ${SIGNING_IDENTITY}"
  CODESIGN_ARGS=(
    --force
    --deep
    --sign "${SIGNING_IDENTITY}"
    --identifier "${BUNDLE_ID}"
  )
  if [[ "${SIGNING_IDENTITY}" == "Developer ID Application:"* ]]; then
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
