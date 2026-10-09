#!/usr/bin/env bash
# Copy the shepaw CLI into a macOS .app and re-sign so notarization still covers it.
#
# The binary lands at Contents/Resources/shepaw. The app copies it to
# ~/.shepaw/bin on launch (see lib/services/cli_bundle.dart).
#
# Source, first match:
#   $SHEPAW_CLI_BIN
#   ../shepaw-cli/target/{aarch64,x86_64}-apple-darwin/release/shepaw  (lipo if both exist)
#   ../shepaw-cli/target/release/shepaw
#
# Usage:
#   tool/bundle_cli.sh [--mode release|debug] /path/to/ShePaw.app

set -euo pipefail

MODE="release"
APP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *)
      APP="$1"
      shift
      ;;
  esac
done

if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "usage: tool/bundle_cli.sh [--mode release|debug] ShePaw.app" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI_REPO="$(cd "$ROOT/../shepaw-cli" 2>/dev/null && pwd || true)"

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }

find_cli() {
  if [[ -n "${SHEPAW_CLI_BIN:-}" && -f "$SHEPAW_CLI_BIN" ]]; then
    printf '%s' "$SHEPAW_CLI_BIN"
    return 0
  fi
  [[ -n "$CLI_REPO" ]] || return 1
  local arm="$CLI_REPO/target/aarch64-apple-darwin/release/shepaw"
  local x64="$CLI_REPO/target/x86_64-apple-darwin/release/shepaw"
  local host="$CLI_REPO/target/release/shepaw"
  if [[ -f "$arm" && -f "$x64" ]]; then
    local uni
    uni="$(mktemp)"
    lipo -create -output "$uni" "$arm" "$x64"
    printf '%s' "$uni"
    return 0
  fi
  if [[ -f "$host" ]]; then
    printf '%s' "$host"
    return 0
  fi
  return 1
}

SRC=""
if ! SRC="$(find_cli)"; then
  if [[ "$MODE" == "release" ]]; then
    echo "shepaw CLI binary not found. Build ../shepaw-cli (cargo build --release) or set SHEPAW_CLI_BIN." >&2
    exit 1
  fi
  warn "shepaw CLI not bundled ($MODE build, binary missing)."
  exit 0
fi

DEST="$APP/Contents/Resources/shepaw"
mkdir -p "$(dirname "$DEST")"

# Read the signature before the bundle changes, so re-sign can keep entitlements.
ENT="$(mktemp)"
cleanup() {
  rm -f "$ENT"
  if [[ -n "${SHEPAW_CLI_BIN:-}" ]]; then
    return 0
  fi
  case "$SRC" in
    /var/folders/*|/tmp/*) rm -f "$SRC" ;;
  esac
}
trap cleanup EXIT

codesign -d --entitlements :- "$APP" > "$ENT" 2>/dev/null || : > "$ENT"

# Authority= only shows up at -vvv. The first one is the signing identity.
# `head` closes the pipe early; `|| true` keeps pipefail from aborting the build.
SIGN_ID="$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1 || true)"
if [[ -z "$SIGN_ID" ]]; then
  SIGN_ID="-"
fi

cp "$SRC" "$DEST"
chmod 755 "$DEST"

APP_BIN="$APP/Contents/MacOS/ShePaw"
if [[ -f "$APP_BIN" ]] && lipo -info "$APP_BIN" 2>/dev/null | grep -q 'x86_64'; then
  if ! lipo -info "$DEST" 2>/dev/null | grep -q 'x86_64'; then
    warn "ShePaw.app has an x86_64 slice but the bundled CLI does not. Intel Macs cannot run this CLI."
  fi
fi

sign_args=(--force --sign "$SIGN_ID")
if [[ "$SIGN_ID" != "-" ]]; then
  sign_args+=(--options runtime --timestamp)
fi

info "Signing bundled CLI as: $SIGN_ID"
codesign "${sign_args[@]}" "$DEST"
if grep -q '<dict>' "$ENT"; then
  codesign "${sign_args[@]}" --entitlements "$ENT" "$APP"
else
  codesign "${sign_args[@]}" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"
info "Bundled CLI → $DEST"
