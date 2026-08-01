#!/usr/bin/env bash
# ShePaw — local release build from data/ (signing secrets live here, not in git)
#
# Usage:
#   ./data/build.sh                  # all host-supported platforms
#   ./data/build.sh android
#   ./data/build.sh macos
#   ./data/build.sh android --debug
#   ./data/build.sh --help
#
# Expects:
#   data/key.properties
#   data/<storeFile from key.properties>   e.g. data/shepaw-release.jks

set -euo pipefail

DATA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$DATA_DIR/.." && pwd)"
cd "$ROOT_DIR"

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
  RED= GREEN= YELLOW= BLUE= NC=
fi

info()    { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
success() { printf '%s[OK]%s %s\n' "$GREEN" "$NC" "$*"; }
warn()    { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
error()   { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; }
die()     { error "$*"; exit 1; }

usage() {
  cat <<'EOF'
ShePaw local build (data/)

Usage:
  ./data/build.sh [platforms...] [options]

Platforms (same as build_all.sh):
  android | android-apk | android-aab | ios | macos | all

Options:
  --release | --debug
  --clean
  --skip-pub-get
  --out <dir>     default: data/out
  -h | --help

Signing (gitignored):
  data/key.properties
  data/shepaw-release.jks   (or path in storeFile=)

First-time setup:
  cp data/key.properties.example data/key.properties
  # edit passwords; place .jks next to key.properties
EOF
}

OUTPUT_DIR="data/out"
FORWARD_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out)
      [[ $# -ge 2 ]] || die "--out requires a directory"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    *)
      FORWARD_ARGS+=("$1")
      shift
      ;;
  esac
done

# ── signing check ───────────────────────────────────────────────────
KEY_PROPS="$DATA_DIR/key.properties"
if [[ ! -f "$KEY_PROPS" ]]; then
  die "Missing $KEY_PROPS — copy data/key.properties.example and fill real values"
fi

if grep -q 'storePassword=<your-store-password>' "$KEY_PROPS" 2>/dev/null; then
  die "$KEY_PROPS still has placeholder passwords"
fi

STORE_FILE_REL="$(
  grep -E '^storeFile=' "$KEY_PROPS" | head -1 | cut -d= -f2- | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
)"
if [[ -z "$STORE_FILE_REL" ]]; then
  die "storeFile= missing in $KEY_PROPS"
fi

if [[ "$STORE_FILE_REL" = /* ]]; then
  STORE_FILE_ABS="$STORE_FILE_REL"
else
  STORE_FILE_ABS="$DATA_DIR/$STORE_FILE_REL"
fi

if [[ ! -f "$STORE_FILE_ABS" ]]; then
  # Helpful fallback: existing project keystore
  LEGACY_JKS="$ROOT_DIR/android/app/shepaw-release.jks"
  if [[ -f "$LEGACY_JKS" && "$STORE_FILE_REL" == "shepaw-release.jks" ]]; then
    warn "Keystore not in data/ — linking android/app/shepaw-release.jks → data/shepaw-release.jks"
    ln -sf "../android/app/shepaw-release.jks" "$DATA_DIR/shepaw-release.jks"
    STORE_FILE_ABS="$DATA_DIR/shepaw-release.jks"
  else
    die "Keystore not found: $STORE_FILE_ABS
Place the .jks next to data/key.properties (storeFile=$STORE_FILE_REL)"
  fi
fi

info "Using signing: $KEY_PROPS"
info "Using keystore: $STORE_FILE_ABS"

# Prefer data/ over android/key.properties for Gradle (build.gradle already prefers data/)
# Ensure android/key.properties does not accidentally override with placeholders —
# Gradle loads data/ first, so we only warn.
if [[ -f "$ROOT_DIR/android/key.properties" ]]; then
  if grep -q 'storePassword=<your-store-password>' "$ROOT_DIR/android/key.properties" 2>/dev/null; then
    info "android/key.properties is placeholder (ignored; data/ takes precedence)"
  fi
fi

mkdir -p "$OUTPUT_DIR"

if [[ ! -x "$ROOT_DIR/build_all.sh" ]]; then
  chmod +x "$ROOT_DIR/build_all.sh" 2>/dev/null || true
fi

info "Delegating to ./build_all.sh (out=$OUTPUT_DIR)"
exec "$ROOT_DIR/build_all.sh" "${FORWARD_ARGS[@]}" --out "$OUTPUT_DIR"
