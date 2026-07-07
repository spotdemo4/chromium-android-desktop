#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Build Chromium Android Desktop with extension support and proprietary codecs.

Usage:
  ./build.sh

Environment overrides:
  WORKSPACE                Local workspace mounted into Docker (default: script directory)
  CONTAINER_NAME           Docker container name (default: chromium-android-builder)
  UBUNTU_IMAGE             Docker image (default: ubuntu:24.04)
  BUILD_DIR                Chromium output dir (default: out/android-desktop-codecs-release)
  LOCAL_APK                Local APK path (default: ./ChromePublic_arm64.apk)
  ENABLE_HEVC              1 to enable platform HEVC/H.265, 0 to disable (default: 1)
  SYNC_CHROMIUM            1 to run gclient sync on an existing checkout (default: 0)
  FORCE_INSTALL_BUILD_DEPS 1 to rerun install-build-deps.sh (default: 0)
  APPLY_CHROMIUM_PATCHES   1 to apply ./patches/*.patch before building (default: 1)
  PATCH_DIR                Patch directory (default: ./patches next to build.sh)

Examples:
  ./build.sh
  WORKSPACE=/home/trev/Dev/chromium-android ./build.sh
  ENABLE_HEVC=0 LOCAL_APK=./ChromePublic-no-hevc.apk ./build.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
WORKSPACE=${WORKSPACE:-$SCRIPT_DIR}
CONTAINER_NAME=${CONTAINER_NAME:-chromium-android-builder}
UBUNTU_IMAGE=${UBUNTU_IMAGE:-ubuntu:24.04}
BUILD_DIR=${BUILD_DIR:-out/android-desktop-codecs-release}
LOCAL_APK=${LOCAL_APK:-"$PWD/ChromePublic_arm64.apk"}
ENABLE_HEVC=${ENABLE_HEVC:-1}
SYNC_CHROMIUM=${SYNC_CHROMIUM:-0}
FORCE_INSTALL_BUILD_DEPS=${FORCE_INSTALL_BUILD_DEPS:-0}
APPLY_CHROMIUM_PATCHES=${APPLY_CHROMIUM_PATCHES:-1}
PATCH_DIR=${PATCH_DIR:-"$SCRIPT_DIR/patches"}

quote() {
  printf '%q' "$1"
}

step() {
  printf '\n==> %s\n' "$*"
}

container_root() {
  local workdir=$1
  local cmd=$2
  docker exec -w "$workdir" "$CONTAINER_NAME" bash -lc "$cmd"
}

container_ubuntu() {
  local workdir=$1
  local cmd=$2
  docker exec \
    -u ubuntu \
    -e HOME=/home/ubuntu \
    -e GCLIENT_SUPPRESS_GIT_VERSION_WARNING=1 \
    -e PATH=/workspace/depot_tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    -w "$workdir" \
    "$CONTAINER_NAME" \
    bash -lc "$cmd"
}

container_ubuntu_script() {
  local workdir=$1
  docker exec \
    -u ubuntu \
    -e HOME=/home/ubuntu \
    -e GCLIENT_SUPPRESS_GIT_VERSION_WARNING=1 \
    -e PATH=/workspace/depot_tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    -w "$workdir" \
    "$CONTAINER_NAME" \
    bash -s
}

create_container() {
  docker run -d \
    --name "$CONTAINER_NAME" \
    -v "$WORKSPACE:/workspace" \
    -w /workspace \
    "$UBUNTU_IMAGE" sleep infinity >/dev/null
}

recreate_container() {
  printf '%s; recreating Docker builder container.\n' "$1"
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  create_container
}

BUILD_LOG="/workspace/build-android-desktop-codecs-release.log"

if [[ "$ENABLE_HEVC" != "0" && "$ENABLE_HEVC" != "1" ]]; then
  printf 'ENABLE_HEVC must be 0 or 1, got: %s\n' "$ENABLE_HEVC" >&2
  exit 2
fi

if [[ "$APPLY_CHROMIUM_PATCHES" != "0" && "$APPLY_CHROMIUM_PATCHES" != "1" ]]; then
  printf 'APPLY_CHROMIUM_PATCHES must be 0 or 1, got: %s\n' "$APPLY_CHROMIUM_PATCHES" >&2
  exit 2
fi

step "Ensuring local workspace exists: $WORKSPACE"
mkdir -p "$WORKSPACE"
WORKSPACE=$(cd -- "$WORKSPACE" && pwd -P)
OUTPUT_APK="$WORKSPACE/chromium/src/$BUILD_DIR/apks/ChromePublic.apk"

step "Checking local build host"
hostname
nproc
free -h | sed -n "1,2p"
df -h "$WORKSPACE"

step "Ensuring Docker builder container exists"
if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  existing_workspace=$(
    docker inspect \
      --format '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}' \
      "$CONTAINER_NAME"
  )
  if [[ "$existing_workspace" != "$WORKSPACE" ]]; then
    recreate_container "Existing container has /workspace mounted from ${existing_workspace:-nothing}, expected $WORKSPACE"
  else
    if ! docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
      docker start "$CONTAINER_NAME" >/dev/null
    fi
    if ! docker exec -w /workspace "$CONTAINER_NAME" true >/dev/null 2>&1; then
      recreate_container "Existing container cannot exec from /workspace"
    fi
  fi
else
  create_container
fi

step "Installing base packages in container if needed"
container_root /workspace '
  if [ ! -f /root/.chromium-android-base-packages.done ]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      git python3 curl ca-certificates lsb-release xz-utils file sudo locales procps
    touch /root/.chromium-android-base-packages.done
  fi
'

step "Ensuring mounted workspace is writable in container"
container_root /workspace 'chmod a+rwx /workspace'

step "Cloning depot_tools if needed"
container_ubuntu /workspace '
  if [ ! -d /workspace/depot_tools/.git ]; then
    rm -rf /workspace/depot_tools.tmp
    if ! git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git /workspace/depot_tools.tmp; then
      rm -rf /workspace/depot_tools.tmp
      git clone https://github.com/chromium/depot_tools.git /workspace/depot_tools.tmp
    fi
    rm -rf /workspace/depot_tools
    mv /workspace/depot_tools.tmp /workspace/depot_tools
  fi
'

step "Fetching Chromium Android source if needed"
container_ubuntu /workspace 'mkdir -p /workspace/chromium'
if ! container_ubuntu /workspace 'test -d /workspace/chromium/src/.git'; then
  container_ubuntu /workspace/chromium 'fetch --nohooks --no-history android'
elif [[ "$SYNC_CHROMIUM" == "1" ]]; then
  step "Syncing existing Chromium checkout"
  container_ubuntu /workspace/chromium 'gclient sync --nohooks --no-history'
else
  printf 'Existing Chromium checkout found; set SYNC_CHROMIUM=1 to update it.\n'
fi

if [[ "$APPLY_CHROMIUM_PATCHES" == "1" ]]; then
  if [[ -d "$PATCH_DIR" ]]; then
    step "Applying Chromium patches from $PATCH_DIR"
    container_root /workspace 'rm -rf /tmp/chromium-android-patches && mkdir -p /tmp/chromium-android-patches && chmod 755 /tmp/chromium-android-patches'
    docker cp "$PATCH_DIR/." "$CONTAINER_NAME:/tmp/chromium-android-patches/"
    container_ubuntu_script /workspace/chromium/src <<'EOF'
      set -e
      shopt -s nullglob
      patches=(/tmp/chromium-android-patches/*.patch)
      if [ ${#patches[@]} -eq 0 ]; then
        printf "No patch files found.\n"
      fi
      for patch in "${patches[@]}"; do
        if git apply --check --reverse "$patch" >/dev/null 2>&1; then
          printf "Patch already applied: %s\n" "$(basename "$patch")"
        else
          git apply --check "$patch"
          git apply "$patch"
          printf "Applied patch: %s\n" "$(basename "$patch")"
        fi
      done
EOF
  else
    printf 'Patch directory not found; skipping Chromium patches: %s\n' "$PATCH_DIR"
  fi
fi

step "Installing Chromium build dependencies if needed"
if [[ "$FORCE_INSTALL_BUILD_DEPS" == "1" ]]; then
  container_root /workspace 'rm -f /root/.chromium-android-install-build-deps.done'
fi
container_root /workspace/chromium/src '
  if [ ! -f /root/.chromium-android-install-build-deps.done ]; then
    build/install-build-deps.sh --no-prompt
    touch /root/.chromium-android-install-build-deps.done
  fi
'

step "Running Chromium hooks"
container_ubuntu /workspace/chromium 'gclient runhooks'

HEVC_ARGS='enable_hevc_parser_and_hw_decoder=false enable_platform_hevc=false'
if [[ "$ENABLE_HEVC" == "1" ]]; then
  HEVC_ARGS='enable_hevc_parser_and_hw_decoder=true enable_platform_hevc=true'
fi

GN_ARGS="target_os=\"android\"
target_cpu=\"arm64\"
is_desktop_android=true
is_debug=false
is_official_build=true
is_unsafe_developer_build=false
is_component_build=false
symbol_level=0
blink_symbol_level=0
v8_symbol_level=0
proprietary_codecs=true
ffmpeg_branding=\"Chrome\"
$HEVC_ARGS
dcheck_always_on=false
enable_expensive_dchecks=false
partition_alloc_dcheck_always_on=false
v8_dcheck_always_on=false
chrome_pgo_phase=0
v8_builtins_profiling_log_file=\"\"
treat_warnings_as_errors=false
use_remoteexec=false
android_static_analysis=\"off\""

step "Generating GN build files in $BUILD_DIR"
container_ubuntu /workspace/chromium/src "gn gen $(quote "$BUILD_DIR") --args=$(quote "$GN_ARGS")"

step "Building chrome_public_apk"
container_ubuntu /workspace/chromium/src "set -o pipefail; autoninja -C $(quote "$BUILD_DIR") chrome_public_apk 2>&1 | tee $(quote "$BUILD_LOG")"

step "Verifying built APK"
test -f "$OUTPUT_APK"
ls -lh "$OUTPUT_APK"
sha256sum "$OUTPUT_APK"

step "Copying APK to $LOCAL_APK"
mkdir -p "$(dirname "$LOCAL_APK")"
cp "$OUTPUT_APK" "$LOCAL_APK"

step "Done"
ls -lh "$LOCAL_APK"
sha256sum "$LOCAL_APK"
