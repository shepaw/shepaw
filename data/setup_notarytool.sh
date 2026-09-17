#!/usr/bin/env bash
# Store App Store Connect API credentials for `xcrun notarytool`.
#
# 1. https://appstoreconnect.apple.com/access/integrations/api
#    Generate API Key（名称 ShePaw Notary，权限 Developer 或 Admin）
# 2. 下载 AuthKey_<KEYID>.p8（只允许下一次）放到 data/apple/ 或 ~/Downloads
# 3. 把页面上的 Issuer ID（UUID）写入 data/apple.properties：
#      NOTARY_ISSUER=<uuid>
# 4. 再跑： ./data/setup_notarytool.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APPLE_DIR="$ROOT_DIR/data/apple"
PROPS="$ROOT_DIR/data/apple.properties"
mkdir -p "$APPLE_DIR"

read_prop() {
  local key="$1"
  [[ -f "$PROPS" ]] || return 0
  grep -E "^${key}=" "$PROPS" | head -1 | cut -d= -f2- | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

PROFILE="$(read_prop NOTARY_PROFILE)"
PROFILE="${PROFILE:-shepaw}"
TEAM="$(read_prop DEVELOPMENT_TEAM)"
TEAM="${TEAM:-6RC5RHX8LH}"
ISSUER="$(read_prop NOTARY_ISSUER)"
KEY_ID="$(read_prop NOTARY_KEY_ID)"

p8=""
shopt -s nullglob
candidates=(
  "$APPLE_DIR"/AuthKey_*.p8
  "$HOME/Downloads"/AuthKey_*.p8
)
shopt -u nullglob
if [[ ${#candidates[@]} -gt 0 ]]; then
  p8="$(ls -t "${candidates[@]}" 2>/dev/null | head -1 || true)"
fi

if [[ -n "$p8" && -z "$KEY_ID" ]]; then
  KEY_ID="$(basename "$p8" | sed -n 's/^AuthKey_\([A-Z0-9]*\)\.p8$/\1/p')"
fi

if [[ -z "$p8" || -z "$ISSUER" || -z "$KEY_ID" ]]; then
  cat <<EOF
还缺 App Store Connect API 密钥，notarytool 没法入库。

1. 打开 https://appstoreconnect.apple.com/access/integrations/api
   （Account Holder / Admin 才能建钥匙）
2. Generate API Key，名称填 ShePaw Notary，Access 选 Developer 或 Admin
3. 下载 AuthKey_<KEYID>.p8，放到：
     $APPLE_DIR/
   或 ~/Downloads/
4. 把页面顶部的 Issuer ID（UUID）写进 data/apple.properties：

     NOTARY_PROFILE=$PROFILE
     NOTARY_ISSUER=<issuer-uuid>
     NOTARY_KEY_ID=<10-char-key-id>

5. 再运行：  ./data/setup_notarytool.sh

当前：
  p8      = ${p8:-missing}
  issuer  = ${ISSUER:-missing}
  key-id  = ${KEY_ID:-missing}
EOF
  exit 1
fi

dest="$APPLE_DIR/AuthKey_${KEY_ID}.p8"
if [[ "$p8" != "$dest" ]]; then
  cp "$p8" "$dest"
  chmod 600 "$dest"
fi

# 把 KEY_ID 回写进 apple.properties，避免下次再猜文件名
if grep -qE '^NOTARY_KEY_ID=' "$PROPS" 2>/dev/null; then
  sed -i.bak "s/^NOTARY_KEY_ID=.*/NOTARY_KEY_ID=$KEY_ID/" "$PROPS"
  rm -f "${PROPS}.bak"
else
  printf 'NOTARY_KEY_ID=%s\n' "$KEY_ID" >> "$PROPS"
fi
if ! grep -qE '^NOTARY_PROFILE=' "$PROPS" 2>/dev/null; then
  printf 'NOTARY_PROFILE=%s\n' "$PROFILE" >> "$PROPS"
fi

echo "Storing notarytool profile '$PROFILE' (team=$TEAM key=$KEY_ID)..."
xcrun notarytool store-credentials "$PROFILE" \
  --key "$dest" \
  --key-id "$KEY_ID" \
  --issuer "$ISSUER" \
  --validate

echo
echo "OK. Profile '$PROFILE' is in the login keychain."
xcrun notarytool history --keychain-profile "$PROFILE" | head -20
