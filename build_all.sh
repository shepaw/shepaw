#!/usr/bin/env bash
# ShePaw — multi-platform build script
#
# Usage:
#   ./build_all.sh                  # build all platforms available on this host
#   ./build_all.sh android          # APK (release) + AAB if signed
#   ./build_all.sh android-apk
#   ./build_all.sh android-aab
#   ./build_all.sh ios
#   ./build_all.sh macos
#   ./build_all.sh web
#   ./build_all.sh android macos web
#   ./build_all.sh all --debug
#
# Options:
#   --release | --debug     Build mode (default: --release)
#   --clean                 flutter clean before build
#   --skip-pub-get          Skip flutter pub get
#   --out <dir>             Output directory (default: dist)
#   -h | --help             Show help
#
# Note: Windows desktop cannot be cross-compiled. Build on a Windows host
# (with Visual Studio) after `flutter create --platforms=windows .`.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

# ── colors ──────────────────────────────────────────────────────────
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

die() { error "$*"; exit 1; }

usage() {
  cat <<'EOF'
ShePaw multi-platform build

Usage:
  ./build_all.sh [platforms...] [options]

Platforms:
  android       Release APK (+ AAB when android/key.properties exists)
  android-apk   APK only
  android-aab   App Bundle only (requires signing)
  ios           iOS (macOS + Xcode; --no-codesign)
  macos         macOS .app archive
  web           Web build
  all           android + ios + macos + web (host-supported only)

  windows       Prefer build_windows.ps1 on a Windows host (kept for discovery).
                This bash target only errors on non-Windows machines.

Options:
  --release | --debug     Build mode (default: --release)
  --clean                 flutter clean before build
  --skip-pub-get          Skip flutter pub get
  --out <dir>             Output directory (default: dist)
  -h | --help             Show help

Examples:
  ./build_all.sh macos web
  ./build_all.sh android --debug
  ./build_all.sh all --clean --out releases
EOF
}

# ── defaults / args ─────────────────────────────────────────────────
BUILD_MODE="release"
DO_CLEAN=0
SKIP_PUB_GET=0
OUTPUT_DIR="dist"
RAW_TARGETS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --release) BUILD_MODE="release"; shift ;;
    --debug)   BUILD_MODE="debug"; shift ;;
    --clean)   DO_CLEAN=1; shift ;;
    --skip-pub-get) SKIP_PUB_GET=1; shift ;;
    --out)
      [[ $# -ge 2 ]] || die "--out requires a directory"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    all|android|android-apk|android-aab|ios|macos|web|windows)
      RAW_TARGETS="${RAW_TARGETS} $1"
      shift
      ;;
    -*)
      die "Unknown option: $1 (try --help)"
      ;;
    *)
      die "Unknown platform: $1 (try --help)"
      ;;
  esac
done

if [[ -z "${RAW_TARGETS// }" ]]; then
  RAW_TARGETS="all"
fi

# Expand aliases and de-dupe (bash 3.2 compatible — no mapfile)
TARGETS=""
for t in $RAW_TARGETS; do
  case "$t" in
    # Windows is intentionally excluded from `all`: Flutter cannot cross-compile
    # Windows desktop from macOS/Linux.
    all)     expand="android-apk android-aab ios macos web" ;;
    android) expand="android-apk android-aab" ;;
    *)       expand="$t" ;;
  esac
  for e in $expand; do
    case " $TARGETS " in
      *" $e "*) ;;
      *) TARGETS="${TARGETS} $e" ;;
    esac
  done
done
TARGETS="$(echo "$TARGETS" | xargs)"

# ── helpers ─────────────────────────────────────────────────────────
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Command not found: $1"
}

is_macos()  { [[ "$(uname -s)" == "Darwin" ]]; }
is_windows() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|Windows_NT) return 0 ;;
    *) return 1 ;;
  esac
}

read_version() {
  local line
  line="$(grep -E '^version:' pubspec.yaml | head -1 | awk '{print $2}')"
  echo "${line:-0.0.0+0}"
}

VERSION="$(read_version)"
VERSION_NAME="${VERSION%%+*}"
BUILD_NUMBER="${VERSION##*+}"
[[ "$BUILD_NUMBER" == "$VERSION" ]] && BUILD_NUMBER="1"

ARTIFACT_PREFIX="shepaw-${VERSION_NAME}"
STAMP="$(date +%Y%m%d-%H%M%S)"

has_android_signing() {
  local props=""
  if [[ -f data/key.properties ]]; then
    props="data/key.properties"
  elif [[ -f android/key.properties ]]; then
    props="android/key.properties"
  else
    return 1
  fi
  if grep -q 'storePassword=<your-store-password>' "$props" 2>/dev/null; then
    return 1
  fi
  if grep -qE '^storePassword=\s*$' "$props" 2>/dev/null; then
    return 1
  fi
  return 0
}

copy_artifact() {
  local src="$1" dest_name="$2"
  [[ -e "$src" ]] || die "Build artifact missing: $src"
  mkdir -p "$OUTPUT_DIR"
  if [[ -d "$src" ]]; then
    rm -rf "$OUTPUT_DIR/$dest_name"
    cp -R "$src" "$OUTPUT_DIR/$dest_name"
  else
    cp "$src" "$OUTPUT_DIR/$dest_name"
  fi
  success "→ $OUTPUT_DIR/$dest_name"
}

archive_dir() {
  local src_dir="$1" archive_name="$2" inner_name="${3:-}"
  mkdir -p "$OUTPUT_DIR"
  local parent base
  parent="$(dirname "$src_dir")"
  base="$(basename "$src_dir")"
  if [[ -n "$inner_name" && "$base" != "$inner_name" ]]; then
    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/shepaw-build.XXXXXX")"
    cp -R "$src_dir" "$tmp/$inner_name"
    tar -czf "$OUTPUT_DIR/$archive_name" -C "$tmp" "$inner_name"
    rm -rf "$tmp"
  else
    tar -czf "$OUTPUT_DIR/$archive_name" -C "$parent" "$base"
  fi
  success "→ $OUTPUT_DIR/$archive_name"
}

find_macos_app() {
  local release_dir="build/macos/Build/Products/Release"
  if [[ -d "$release_dir/ShePaw.app" ]]; then
    echo "$release_dir/ShePaw.app"
    return 0
  fi
  if [[ -d "$release_dir/shepaw.app" ]]; then
    echo "$release_dir/shepaw.app"
    return 0
  fi
  local app
  app="$(find "$release_dir" -maxdepth 1 -type d -name '*.app' 2>/dev/null | head -1 || true)"
  [[ -n "$app" ]] || return 1
  echo "$app"
}

# ── prepare ─────────────────────────────────────────────────────────
prepare() {
  require_cmd flutter
  require_cmd tar

  info "ShePaw build  version=$VERSION  mode=$BUILD_MODE  out=$OUTPUT_DIR"
  info "Targets: $TARGETS"
  info "Flutter: $(flutter --version 2>/dev/null | head -1)"

  mkdir -p "$OUTPUT_DIR"

  if [[ "$DO_CLEAN" -eq 1 ]]; then
    info "flutter clean..."
    flutter clean
  fi

  if [[ "$SKIP_PUB_GET" -eq 0 ]]; then
    info "flutter pub get..."
    flutter pub get
  fi
}

# ── platform builders ───────────────────────────────────────────────
build_android_apk() {
  info "Building Android APK ($BUILD_MODE)..."
  if [[ "$BUILD_MODE" == "release" ]]; then
    if ! has_android_signing; then
      warn "android/key.properties missing or still a placeholder — release signing may fail."
      warn "Copy android/key.properties.example → android/key.properties and fill real values."
    fi
    flutter build apk --release
    copy_artifact \
      "build/app/outputs/flutter-apk/app-release.apk" \
      "${ARTIFACT_PREFIX}-android-release.apk"
  else
    flutter build apk --debug
    copy_artifact \
      "build/app/outputs/flutter-apk/app-debug.apk" \
      "${ARTIFACT_PREFIX}-android-debug.apk"
  fi
}

build_android_aab() {
  info "Building Android App Bundle..."
  if [[ "$BUILD_MODE" != "release" ]]; then
    warn "AAB is release-only; forcing --release for android-aab"
  fi
  if ! has_android_signing; then
    warn "Skip AAB: need a real android/key.properties (see key.properties.example)"
    return 0
  fi
  flutter build appbundle --release
  copy_artifact \
    "build/app/outputs/bundle/release/app-release.aab" \
    "${ARTIFACT_PREFIX}-android-release.aab"
}

build_ios() {
  if ! is_macos; then
    warn "Skip iOS: requires macOS + Xcode"
    return 0
  fi
  if ! command -v xcodebuild >/dev/null 2>&1; then
    warn "Skip iOS: xcodebuild not found"
    return 0
  fi
  info "Building iOS ($BUILD_MODE, no-codesign)..."
  if [[ "$BUILD_MODE" == "release" ]]; then
    flutter build ios --release --no-codesign
  else
    flutter build ios --debug --no-codesign
  fi
  local app_dir
  app_dir="$(find build/ios -type d -name 'Runner.app' 2>/dev/null | head -1 || true)"
  if [[ -n "$app_dir" ]]; then
    archive_dir "$app_dir" "${ARTIFACT_PREFIX}-ios-${BUILD_MODE}.tar.gz" "Runner.app"
  else
    warn "iOS build finished but Runner.app not found under build/ios (open ios/Runner.xcworkspace to archive/sign)"
  fi
  info "Tip: open ios/Runner.xcworkspace in Xcode to sign & distribute"
}

build_macos() {
  if ! is_macos; then
    warn "Skip macOS: requires macOS"
    return 0
  fi
  info "Building macOS ($BUILD_MODE)..."
  flutter build macos "--${BUILD_MODE}"

  local app
  if ! app="$(find_macos_app)"; then
    die "macOS .app not found under build/macos/Build/Products/Release"
  fi
  local app_name
  app_name="$(basename "$app")"
  archive_dir "$app" "${ARTIFACT_PREFIX}-macos-${BUILD_MODE}.tar.gz" "$app_name"
  copy_artifact "$app" "$app_name"
}

build_web() {
  info "Building Web ($BUILD_MODE)..."
  flutter build web "--${BUILD_MODE}"
  archive_dir "build/web" "${ARTIFACT_PREFIX}-web-${BUILD_MODE}.tar.gz" "web"
  copy_artifact "build/web" "web"
}

build_windows() {
  # Flutter desktop Windows builds require a Windows host + MSVC toolchain.
  # Prefer the dedicated PowerShell script on Windows.
  if ! is_windows; then
    error "Windows builds must run on Windows."
    error "On a Windows machine use:  .\\build_windows.ps1   (or build_windows.bat)"
    error "Optional first-time setup:  .\\build_windows.ps1 -Init"
    return 1
  fi
  if [[ ! -d windows ]]; then
    error "No windows/ folder. Run: .\\build_windows.ps1 -Init"
    return 1
  fi
  info "Building Windows ($BUILD_MODE) via flutter..."
  info "Tip: prefer .\\build_windows.ps1 for zip packaging on Windows."
  flutter build windows "--${BUILD_MODE}"
  local win_dir="build/windows/x64/runner/Release"
  if [[ ! -d "$win_dir" ]]; then
    win_dir="build/windows/runner/Release"
  fi
  [[ -d "$win_dir" ]] || die "Windows Release folder not found"
  archive_dir "$win_dir" "${ARTIFACT_PREFIX}-windows-${BUILD_MODE}.tar.gz" "ShePaw"
}

write_report() {
  local report="$OUTPUT_DIR/build-report-${STAMP}.txt"
  {
    echo "ShePaw build report"
    echo "time:     $(date)"
    echo "version:  $VERSION (name=$VERSION_NAME build=$BUILD_NUMBER)"
    echo "mode:     $BUILD_MODE"
    echo "targets:  $TARGETS"
    echo "host:     $(uname -a)"
    echo "flutter:  $(flutter --version 2>/dev/null | head -1)"
    echo ""
    echo "artifacts:"
    ls -lh "$OUTPUT_DIR" 2>/dev/null || true
  } > "$report"
  success "Report: $report"
}

# ── main ────────────────────────────────────────────────────────────
FAILED=0
SUCCEEDED=""

run_target() {
  local t="$1"
  case "$t" in
    android-apk) build_android_apk ;;
    android-aab) build_android_aab ;;
    ios)         build_ios ;;
    macos)       build_macos ;;
    web)         build_web ;;
    windows)     build_windows ;;
    *) die "Internal error: unknown target $t" ;;
  esac
}

prepare

for t in $TARGETS; do
  echo
  info "======== $t ========"
  if run_target "$t"; then
    SUCCEEDED="${SUCCEEDED} $t"
  else
    error "Target failed: $t"
    FAILED=1
  fi
done

echo
write_report
info "Done. Succeeded:${SUCCEEDED:- none}"
info "Artifacts in: $OUTPUT_DIR/"
ls -lh "$OUTPUT_DIR" || true

exit "$FAILED"
