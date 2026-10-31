#!/bin/sh
set -eu
# Build the host-architecture development core and place it inside the app sandbox.
# A universal release needs separately built slices and an explicit release pipeline.
CORE_DIR="$PROJECT_DIR/../../core"
SOURCE_ROOT="$(cd -P "$CORE_DIR" && cd .. && pwd -P)"
ASSET_DIR="$PROJECT_DIR/../assets"
for asset in map.v1.json seed.v1.json; do
  if ! cmp -s "$SOURCE_ROOT/data/seed/nviai/$asset" "$ASSET_DIR/$asset"; then
    echo "error: $asset differs from data/seed/nviai; review and reconcile the copies before building." >&2
    exit 1
  fi
done
CARGO_BIN="${CARGO_BIN:-$HOME/.cargo/bin/cargo}"
"$CARGO_BIN" build --locked --manifest-path "$CORE_DIR/Cargo.toml"
DESTINATION="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$DESTINATION"
cp "$CORE_DIR/target/debug/libmonastack_core.dylib" "$DESTINATION/libmonastack_core.dylib"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
  /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$DESTINATION/libmonastack_core.dylib"
fi
