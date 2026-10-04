#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
PATCH_FILE="$REPO_ROOT/.github/patches/offline-mode.patch"
BUILD_TYPE="${BUILD_TYPE:-Release}"
BUILD_DIR="$REPO_ROOT/build"
DIST_DIR="${DIST_DIR:-$REPO_ROOT/dist}"
JOBS="${JOBS:-$(nproc)}"
RUN_TESTS="${RUN_TESTS:-1}"
PATCH_APPLIED_BY_SCRIPT=0

restore_patch() {
  if (( PATCH_APPLIED_BY_SCRIPT )); then
    echo "Restoring unpatched source files..."
    git -C "$REPO_ROOT" apply --reverse "$PATCH_FILE" || {
      echo "warning: could not automatically reverse $PATCH_FILE" >&2
      echo "Run: git -C '$REPO_ROOT' apply --reverse '$PATCH_FILE'" >&2
    }
  fi
}
trap restore_patch EXIT

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ "$(uname -s)" == "Linux" ]] || fail "this script only supports Linux"
[[ "$(uname -m)" == "x86_64" ]] || fail "this script requires an x86-64 machine"
[[ -f "$PATCH_FILE" ]] || fail "offline patch not found at $PATCH_FILE"
[[ "$BUILD_TYPE" == "Release" || "$BUILD_TYPE" == "Debug" ]] || fail "BUILD_TYPE must be Release or Debug"
[[ "$RUN_TESTS" == "0" || "$RUN_TESTS" == "1" ]] || fail "RUN_TESTS must be 0 or 1"

if [[ -d /usr/lib/jvm/java-17-openjdk ]]; then
  export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk}"
  export PATH="$JAVA_HOME/bin:$PATH"
fi

for command_name in cmake git ninja pkg-config tar java; do
  command -v "$command_name" >/dev/null || fail "missing command: $command_name"
done

cd "$REPO_ROOT"

echo "Initializing source dependencies..."
git submodule update --init --recursive

if git apply --check "$PATCH_FILE"; then
  echo "Applying offline-mode patch..."
  git apply "$PATCH_FILE"
  PATCH_APPLIED_BY_SCRIPT=1
elif git apply --reverse --check "$PATCH_FILE"; then
  echo "Offline-mode patch is already applied; leaving it applied after the build."
else
  fail "offline-mode patch does not apply cleanly to this source revision"
fi

export ARTIFACT_NAME="Linux-Qt6"
export BUILD_PLATFORM="offline-local"

echo "Configuring $BUILD_TYPE x86-64 build..."
cmake --preset linux \
  -D VCPKG_HOST_TRIPLET=x64-linux \
  -D VCPKG_TARGET_TRIPLET=x64-linux

echo "Building with $JOBS parallel jobs..."
cmake --build --preset linux --config "$BUILD_TYPE" --parallel "$JOBS"

if [[ "$RUN_TESTS" == "1" ]]; then
  echo "Running tests..."
  ctest --preset linux --build-config "$BUILD_TYPE"
fi

SHORT_REVISION="$(git rev-parse --short HEAD)"
BUILD_STAMP="$(date -u +%Y%m%d%H%M%S)"
OUTPUT_NAME="PrismLauncher-offline-${SHORT_REVISION}-${BUILD_TYPE}-x86_64-${BUILD_STAMP}"
STAGE_DIR="$DIST_DIR/$OUTPUT_NAME"
ARCHIVE_PATH="$DIST_DIR/$OUTPUT_NAME.tar.gz"

mkdir -p "$STAGE_DIR"

echo "Installing portable build..."
cmake --install "$BUILD_DIR" --config "$BUILD_TYPE" --prefix "$STAGE_DIR"
cmake --install "$BUILD_DIR" --config "$BUILD_TYPE" --prefix "$STAGE_DIR" --component portable

echo "Creating archive..."
tar -C "$STAGE_DIR" -czf "$ARCHIVE_PATH" .

echo
echo "Portable directory: $STAGE_DIR"
echo "Portable archive:   $ARCHIVE_PATH"
echo "Launcher:           $STAGE_DIR/bin/prismlauncher"
