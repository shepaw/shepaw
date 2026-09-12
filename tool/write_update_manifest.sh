#!/usr/bin/env bash
# 根据 dist/ 产物生成 latest-macos.json / latest-android.json。
# 本脚本只写文件，不上传。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
OUT="$DIST/update"
DOWNLOAD_BASE="https://release.shepaw.com/download"
NOTES=""
MANDATORY="false"

usage() {
  cat <<'EOF'
用法:
  tool/write_update_manifest.sh [选项]

选项:
  --dist DIR           产物目录（默认 dist/）
  --out DIR            JSON 输出目录（默认 dist/update/）
  --download-base URL  安装包公开前缀，文件名拼在后面
                       （默认 https://release.shepaw.com/download）
  --notes TEXT         更新说明（写入 description）
  --notes-file FILE    从文件读取更新说明
  --mandatory          标记为强制更新
  -h, --help           显示帮助

示例:
  ./build_all.sh android-apk macos
  tool/write_update_manifest.sh \
    --download-base https://github.com/OWNER/REPO/releases/download/1.0.23 \
    --notes "修复更新安装"

然后将 dist/ 里的安装包和 dist/update/*.json 上传到对应 URL。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dist) DIST="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --download-base) DOWNLOAD_BASE="$2"; shift 2 ;;
    --notes) NOTES="$2"; shift 2 ;;
    --notes-file) NOTES="$(cat "$2")"; shift 2 ;;
    --mandatory) MANDATORY="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ ! -f "$ROOT/pubspec.yaml" ]]; then
  echo "找不到 pubspec.yaml" >&2
  exit 1
fi

VERSION_LINE="$(grep -E '^version:' "$ROOT/pubspec.yaml" | head -n1 | awk '{print $2}')"
VERSION="${VERSION_LINE%%+*}"
BUILD="${VERSION_LINE#*+}"
if [[ "$BUILD" == "$VERSION_LINE" ]]; then
  BUILD="0"
fi

RELEASE_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DOWNLOAD_BASE="${DOWNLOAD_BASE%/}"

sha256_hex() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1])[1:-1])' "$1"
}

write_manifest() {
  local platform="$1"
  local artifact="$2"
  local extra_json="$3"

  if [[ ! -f "$artifact" ]]; then
    echo "跳过 $platform：找不到 $artifact"
    return 0
  fi

  local name size checksum url desc extra_line
  name="$(basename "$artifact")"
  size="$(wc -c < "$artifact" | tr -d ' ')"
  checksum="$(sha256_hex "$artifact")"
  url="$DOWNLOAD_BASE/$name"
  desc="$(json_escape "$NOTES")"
  extra_line=""
  if [[ -n "$extra_json" ]]; then
    extra_line=",
  $extra_json"
  fi

  mkdir -p "$OUT"
  local dest="$OUT/latest-$platform.json"
  cat > "$dest" <<EOF
{
  "version": "$VERSION",
  "buildNumber": "$BUILD",
  "description": "$desc",
  "isMandatory": $MANDATORY,
  "releaseDate": "$RELEASE_DATE",
  "downloadUrl": "$url",
  "fileSize": $size,
  "checksum": "sha256:$checksum"$extra_line
}
EOF

  echo "已写入 $dest"
  echo "  artifact: $name ($size bytes)"
  echo "  sha256:   $checksum"
  echo "  url:      $url"
}

shopt -s nullglob
apk_candidates=("$DIST"/shepaw-*-android-release.apk)
macos_candidates=("$DIST"/shepaw-*-macos-release.tar.gz)
shopt -u nullglob

apk=""
macos=""
if [[ ${#apk_candidates[@]} -gt 0 ]]; then
  apk="${apk_candidates[0]}"
fi
if [[ ${#macos_candidates[@]} -gt 0 ]]; then
  macos="${macos_candidates[0]}"
fi

echo "version=$VERSION+$BUILD"
echo "dist=$DIST"
echo "out=$OUT"
echo

wrote=0
if [[ -n "$apk" ]]; then
  write_manifest android "$apk" '"minAndroidSdk": 21'
  wrote=1
else
  echo "跳过 android：dist 中没有 shepaw-*-android-release.apk"
fi
if [[ -n "$macos" ]]; then
  write_manifest macos "$macos" '"minMacOSVersion": "11.0"'
  wrote=1
else
  echo "跳过 macos：dist 中没有 shepaw-*-macos-release.tar.gz"
fi

if [[ "$wrote" -eq 0 ]]; then
  echo "没有生成任何清单。请先运行 ./build_all.sh android-apk macos" >&2
  exit 1
fi
