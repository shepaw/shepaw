#!/bin/sh
# Fix macOS framework symlink structure for native asset frameworks.
# Flutter may generate frameworks with real directories instead of symlinks,
# causing codesign to fail with "bundle format is ambiguous".

FRAMEWORKS_DIR="${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}"

if [ ! -d "$FRAMEWORKS_DIR" ]; then
  echo "fix_framework_symlinks.sh: Frameworks dir not found, skipping."
  exit 0
fi

fix_framework() {
  local FRAMEWORK_DIR="$1"
  local FRAMEWORK_NAME=$(basename "$FRAMEWORK_DIR" .framework)

  local VERSIONS_DIR="$FRAMEWORK_DIR/Versions"
  local VERSION_A_DIR="$VERSIONS_DIR/A"
  local CURRENT_LINK="$VERSIONS_DIR/Current"

  # Only fix if Versions/A exists (i.e. this is a versioned framework)
  if [ ! -d "$VERSION_A_DIR" ]; then
    return
  fi

  # Fix Versions/Current: must be a symlink to A, not a real directory
  if [ -d "$CURRENT_LINK" ] && [ ! -L "$CURRENT_LINK" ]; then
    echo "fix_framework_symlinks.sh: Fixing Versions/Current in $FRAMEWORK_NAME.framework"
    rm -rf "$CURRENT_LINK"
    ln -s A "$CURRENT_LINK"
  fi

  # Fix top-level binary symlink
  local BINARY="$FRAMEWORK_DIR/$FRAMEWORK_NAME"
  if [ -f "$BINARY" ] && [ ! -L "$BINARY" ]; then
    echo "fix_framework_symlinks.sh: Fixing binary symlink in $FRAMEWORK_NAME.framework"
    rm -f "$BINARY"
    ln -s "Versions/Current/$FRAMEWORK_NAME" "$BINARY"
  fi

  # Fix top-level Resources symlink
  local RESOURCES="$FRAMEWORK_DIR/Resources"
  if [ -d "$RESOURCES" ] && [ ! -L "$RESOURCES" ]; then
    echo "fix_framework_symlinks.sh: Fixing Resources symlink in $FRAMEWORK_NAME.framework"
    rm -rf "$RESOURCES"
    ln -s "Versions/Current/Resources" "$RESOURCES"
  fi
}

for FRAMEWORK in "$FRAMEWORKS_DIR"/*.framework; do
  if [ -d "$FRAMEWORK" ]; then
    fix_framework "$FRAMEWORK"
  fi
done

echo "fix_framework_symlinks.sh: Done."
