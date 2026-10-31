#!/bin/sh
set -eu
# Build the Rust core and place it inside the app bundle. Debug and Profile
# builds use the host architecture; Release builds an arm64 + x86_64
# universal library to match the universal Flutter app.
CORE_DIR="$PROJECT_DIR/../../core"
SOURCE_ROOT="$(cd -P "$CORE_DIR" && cd .. && pwd -P)"
ASSET_DIR="$PROJECT_DIR/../assets"
for asset in map.v2.json seed.v1.json; do
  if ! cmp -s "$SOURCE_ROOT/data/seed/nviai/$asset" "$ASSET_DIR/$asset"; then
    echo "error: $asset differs from data/seed/nviai; review and reconcile the copies before building." >&2
    exit 1
  fi
done
CARGO_BIN="${CARGO_BIN:-$HOME/.cargo/bin/cargo}"
DESTINATION="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$DESTINATION"
if [ "${CONFIGURATION:-Debug}" = "Release" ]; then
  for target in aarch64-apple-darwin x86_64-apple-darwin; do
    "$CARGO_BIN" build --locked --release --target "$target" --manifest-path "$CORE_DIR/Cargo.toml"
  done
  /usr/bin/lipo -create -output "$DESTINATION/libmonastack_core.dylib" \
    "$CORE_DIR/target/aarch64-apple-darwin/release/libmonastack_core.dylib" \
    "$CORE_DIR/target/x86_64-apple-darwin/release/libmonastack_core.dylib"
else
  "$CARGO_BIN" build --locked --manifest-path "$CORE_DIR/Cargo.toml"
  cp "$CORE_DIR/target/debug/libmonastack_core.dylib" "$DESTINATION/libmonastack_core.dylib"
fi
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
  /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$DESTINATION/libmonastack_core.dylib"
fi
