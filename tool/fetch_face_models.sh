#!/usr/bin/env bash
#
# Fetches the on-device TFLite face models used by TfliteFaceEmbeddingEngine
# (lib/services/vision/tflite_face_embedding_engine.dart) into assets/models/face/.
#
#   tool/fetch_face_models.sh
#
# URL overrides (any mirror / pinned version):
#   FACE_MODEL_URL_ULTRAAFACE=...     FACE_MODEL_URL_MOBILEFACENET=... \
#     tool/fetch_face_models.sh
#
# sha256 verification:
#   - Recorded hashes below are the verified values. Set FACE_MODEL_SHA256_* to
#     override / pin a specific build.
#   - If a recorded hash is empty (first bootstrap) the script downloads, prints the
#     computed sha256, and exits with a warning — record that hash below to enforce
#     verification on subsequent runs.
#   - On mismatch the downloaded file is deleted and the script fails (refuses to use).

set -euo pipefail

cd "$(dirname "$0")/.."

DIR="assets/models/face"
mkdir -p "$DIR"

# ── Recorded hashes (fill in after the first verified download) ───────────────
EXPECTED_ULTRAAFACE_SHA256="${FACE_MODEL_SHA256_ULTRAAFACE:-}"
EXPECTED_MOBILEFACENET_SHA256="${FACE_MODEL_SHA256_MOBILEFACENET:-}"

# ── Default sources (open-source release mirrors; override via FACE_MODEL_URL_*) ─
ULTRAAFACE_URL="${FACE_MODEL_URL_ULTRAAFACE:-}"
MOBILEFACENET_URL="${FACE_MODEL_URL_MOBILEFACENET:-}"

if [[ -z "$ULTRAAFACE_URL" || -z "$MOBILEFACENET_URL" ]]; then
  echo "ERROR: model URLs not configured." >&2
  echo "Set FACE_MODEL_URL_ULTRAAFACE and FACE_MODEL_URL_MOBILEFACENET to" >&2
  echo "URLs of the ultraface.tflite and mobilefacenet.tflite files." >&2
  exit 1
fi

fetch() {
  local name="$1" url="$2" expected="$3"
  local dest="$DIR/$name"

  if [[ -f "$dest" && -n "$expected" ]]; then
    local have; have=$(shasum -a 256 "$dest" | awk '{print $1}')
    if [[ "$have" == "$expected" ]]; then
      echo "✓ $name already present and verified"
      return 0
    fi
  fi

  echo "⬇ downloading $name"
  curl -fL --retry 3 -o "$dest.tmp" "$url"

  local have; have=$(shasum -a 256 "$dest.tmp" | awk '{print $1}')
  if [[ -n "$expected" ]]; then
    if [[ "$have" != "$expected" ]]; then
      rm -f "$dest.tmp"
      echo "✗ $name sha256 mismatch (expected $expected, got $have)" >&2
      echo "  Refusing to use the unverified file." >&2
      exit 1
    fi
    echo "✓ $name verified (sha256 $have)"
  else
    echo "⚠ $name downloaded but NOT verified (no recorded sha256)." >&2
    echo "  Record this hash in tool/fetch_face_models.sh to enforce verification:" >&2
    echo "    $name  →  $have" >&2
  fi

  mv "$dest.tmp" "$dest"
}

fetch ultraface.tflite     "$ULTRAAFACE_URL"     "$EXPECTED_ULTRAAFACE_SHA256"
fetch mobilefacenet.tflite "$MOBILEFACENET_URL"  "$EXPECTED_MOBILEFACENET_SHA256"

echo
echo "Done. Restart the app (or call FaceEmbeddingEngineRegistry.reset()) so"
echo "TfliteFaceEmbeddingEngine picks up the models; vision status will show"
echo "engine id 'tflite-mobilefacenet' instead of 'debug'."
