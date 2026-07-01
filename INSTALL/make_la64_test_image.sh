#!/usr/bin/env bash
# Build a release-like Ventoy LoongArch64 test install directory and raw disk image
# without running the full x86_64-oriented ventoy_pack.sh.
#
# This is intended for LoongArch validation hosts where full packaging fails on
# x86/aarch64/mips helper-tool rebuilds. It uses an official Ventoy Linux release
# package as the base (for boot/boot.img, boot/core.img.xz, and generic helper
# tools), overlays the LoongArch64 files from this source tree, then runs
# Ventoy2Disk.sh against a loop-backed raw image.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
INSTALL_DIR="$REPO_ROOT/INSTALL"

IMAGE=/tmp/ventoy-la64-test.img
IMAGE_SIZE=16G
WORKDIR=/tmp/ventoy-la64-release-test
BASE_TAR=
BASE_DIR=
ISO_PATH=
KEEP=0
SKIP_INSTALL=0

log() { printf '\033[1;34m[la64-test-image]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[la64-test-image][warn]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[la64-test-image][error]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: bash INSTALL/make_la64_test_image.sh [options]

Options:
  --image PATH          Output raw disk image. Default: /tmp/ventoy-la64-test.img
  --size SIZE           Raw disk image size. Default: 16G
  --iso PATH            Optional ISO to copy into partition 1 after install.
  --workdir DIR         Working directory. Default: /tmp/ventoy-la64-release-test
  --base-tar PATH       Existing official ventoy-*-linux.tar.gz to use as base.
  --base-dir DIR        Existing extracted official ventoy-*-linux directory to copy as base.
  --skip-install        Only prepare release-like directory; do not create/install image.
  --keep                Keep workdir after success.
  -h, --help            Show this help.

Typical LoongArch validation flow:
  bash INSTALL/make_la64_test_image.sh --iso /path/to/test.iso

Why this exists:
  Running INSTALL/Ventoy2Disk.sh directly in the source INSTALL/ directory is
  rejected because source trees do not have release boot/boot.img. Full
  ventoy_pack.sh is x86_64-build-host oriented and tries to rebuild i386,
  aarch64, and mips helper tools. This script avoids that by overlaying LA64
  artifacts onto an official release package.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE=${2:?--image needs a path}; shift ;;
    --size) IMAGE_SIZE=${2:?--size needs a value}; shift ;;
    --iso) ISO_PATH=${2:?--iso needs a path}; shift ;;
    --workdir) WORKDIR=${2:?--workdir needs a directory}; shift ;;
    --base-tar) BASE_TAR=${2:?--base-tar needs a path}; shift ;;
    --base-dir) BASE_DIR=${2:?--base-dir needs a directory}; shift ;;
    --skip-install) SKIP_INSTALL=1 ;;
    --keep) KEEP=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
sudo_if_needed() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

version_from_source() {
  local cfg="$INSTALL_DIR/grub/grub.cfg"
  [[ -f "$cfg" ]] || die "missing $cfg"
  awk -F'"' '/set[[:space:]]+VENTOY_VERSION=/ { print $2; exit }' "$cfg"
}

check_source_artifacts() {
  local missing=0
  for p in \
    "$INSTALL_DIR/EFI/BOOT/BOOTLOONGARCH64.EFI" \
    "$INSTALL_DIR/ventoy/ventoy_loongarch64.cpio" \
    "$INSTALL_DIR/ventoy/ventoy_la64.efi" \
    "$INSTALL_DIR/ventoy/vtoyutil_la64.efi" \
    "$INSTALL_DIR/tool/loongarch64"; do
    if [[ ! -e "$p" ]]; then
      warn "missing source artifact: ${p#$REPO_ROOT/}"
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || die "LoongArch64 integration artifacts are missing; run this on the LA64 integration branch, not the GRUB-only baseline"
}

prepare_base_release() {
  local version=$1
  local base_parent="$WORKDIR/base"
  local tar_path="$BASE_TAR"
  rm -rf "$base_parent"
  mkdir -p "$base_parent"

  if [[ -n "$BASE_DIR" ]]; then
    [[ -d "$BASE_DIR" ]] || die "base dir not found: $BASE_DIR"
    log "copying base release dir: $BASE_DIR"
    cp -a "$BASE_DIR" "$base_parent/"
  else
    if [[ -z "$tar_path" ]]; then
      tar_path="$WORKDIR/ventoy-${version}-linux.tar.gz"
      if [[ ! -s "$tar_path" ]]; then
        need_cmd wget
        log "downloading official Ventoy base release v${version}"
        wget --tries=3 --timeout=30 -O "$tar_path" "https://github.com/ventoy/Ventoy/releases/download/v${version}/ventoy-${version}-linux.tar.gz"
      fi
    fi
    [[ -s "$tar_path" ]] || die "base tar not found or empty: $tar_path"
    log "extracting base release tar: $tar_path"
    tar -xzf "$tar_path" -C "$base_parent"
  fi

  local dirs=("$base_parent"/ventoy-*-linux "$base_parent"/ventoy-*)
  local dir
  for dir in "${dirs[@]}"; do
    if [[ -d "$dir" && -f "$dir/Ventoy2Disk.sh" && -d "$dir/boot" && -d "$dir/ventoy" ]]; then
      printf '%s\n' "$dir"
      return
    fi
  done
  die "could not find extracted Ventoy release dir under $base_parent"
}

overlay_la64_artifacts() {
  local release_dir=$1
  need_cmd rsync

  log "overlaying LoongArch64 artifacts onto release base"
  rsync -a "$INSTALL_DIR/grub/" "$release_dir/grub/"
  rsync -a "$INSTALL_DIR/EFI/" "$release_dir/EFI/"
  rsync -a "$INSTALL_DIR/ventoy/" "$release_dir/ventoy/"
  mkdir -p "$release_dir/tool/loongarch64"
  rsync -a "$INSTALL_DIR/tool/loongarch64/" "$release_dir/tool/loongarch64/"

  # Use source scripts/libs so TOOLDIR=loongarch64 and LA64 worker paths are available.
  cp -a "$INSTALL_DIR/Ventoy2Disk.sh" "$release_dir/Ventoy2Disk.sh"
  cp -a "$INSTALL_DIR/VentoyWeb.sh" "$release_dir/VentoyWeb.sh" 2>/dev/null || true
  cp -a "$INSTALL_DIR/tool/VentoyWorker.sh" "$release_dir/tool/VentoyWorker.sh"
  cp -a "$INSTALL_DIR/tool/ventoy_lib.sh" "$release_dir/tool/ventoy_lib.sh"

  [[ -f "$release_dir/boot/boot.img" ]] || die "base release did not provide boot/boot.img"
  [[ -f "$release_dir/boot/core.img.xz" ]] || die "base release did not provide boot/core.img.xz"
  [[ -f "$release_dir/ventoy/ventoy.disk.img.xz" ]] || die "base release did not provide ventoy/ventoy.disk.img.xz"
  [[ -f "$release_dir/EFI/BOOT/BOOTLOONGARCH64.EFI" ]] || die "overlay failed: missing BOOTLOONGARCH64.EFI"
  [[ -d "$release_dir/tool/loongarch64" ]] || die "overlay failed: missing tool/loongarch64"

  chmod +x "$release_dir/Ventoy2Disk.sh"
  chmod +x "$release_dir/tool/VentoyWorker.sh"
  chmod +x -R "$release_dir/tool/loongarch64" || true
}

install_image() {
  local release_dir=$1
  need_cmd truncate
  need_cmd losetup
  need_cmd lsblk

  log "creating raw image: $IMAGE ($IMAGE_SIZE)"
  rm -f "$IMAGE"
  truncate -s "$IMAGE_SIZE" "$IMAGE"

  local loopdev=
  loopdev=$(sudo_if_needed losetup --find --show -P "$IMAGE")
  log "loop device: $loopdev"

  cleanup_loop() {
    if [[ -n "${loopdev:-}" ]]; then
      sudo_if_needed umount "${loopdev}p1" >/dev/null 2>&1 || true
      sudo_if_needed umount "${loopdev}p2" >/dev/null 2>&1 || true
      sudo_if_needed losetup -d "$loopdev" >/dev/null 2>&1 || true
    fi
  }
  trap cleanup_loop EXIT

  log "running Ventoy2Disk.sh from release-like dir"
  (cd "$release_dir" && sudo_if_needed bash ./Ventoy2Disk.sh -I -g "$loopdev")
  sudo_if_needed partprobe "$loopdev" >/dev/null 2>&1 || true
  sleep 1
  lsblk "$loopdev"

  if [[ -n "$ISO_PATH" ]]; then
    [[ -f "$ISO_PATH" ]] || die "ISO not found: $ISO_PATH"
    local mnt="$WORKDIR/mnt-p1"
    mkdir -p "$mnt"
    log "copying ISO to partition 1: $ISO_PATH"
    sudo_if_needed mount "${loopdev}p1" "$mnt"
    local iso_name
    iso_name=$(basename -- "$ISO_PATH")
    sudo_if_needed cp "$ISO_PATH" "$mnt/$iso_name"
    sync
    sudo_if_needed umount "$mnt"
  fi

  local mnt2="$WORKDIR/mnt-p2"
  mkdir -p "$mnt2"
  log "overlaying LoongArch64 files into installed VTOYEFI partition"
  sudo_if_needed mount "${loopdev}p2" "$mnt2"
  sudo_if_needed mkdir -p "$mnt2/EFI" "$mnt2/ventoy" "$mnt2/grub" "$mnt2/tool"
  sudo_if_needed cp -r "$release_dir/EFI/BOOT" "$mnt2/EFI/"
  sudo_if_needed cp -r "$release_dir/ventoy/." "$mnt2/ventoy/"
  sudo_if_needed cp -r "$release_dir/grub/." "$mnt2/grub/"
  if [[ -f "$release_dir/tool/loongarch64/vtoycli" ]]; then
    sudo_if_needed dd status=none bs=1024 count=16       if="$release_dir/tool/loongarch64/vtoycli"       of="$mnt2/tool/mount.exfat-fuse_loongarch64"
  fi
  sync
  log "checking VTOYEFI contents"
  find "$mnt2" -maxdepth 4 \( -iname '*loong*' -o -iname '*la64*' \) -print || true
  ls -lh "$mnt2/EFI/BOOT" || true
  ls -lh "$mnt2/ventoy" | sed -n '1,80p' || true
  sudo_if_needed umount "$mnt2"

  cleanup_loop
  trap - EXIT
  log "image ready: $IMAGE"
}

main() {
  check_source_artifacts
  local version
  version=$(version_from_source)
  [[ -n "$version" && "$version" != "none" ]] || die "could not read VENTOY_VERSION from INSTALL/grub/grub.cfg"
  log "source Ventoy version: $version"

  rm -rf "$WORKDIR"
  mkdir -p "$WORKDIR"
  local release_dir
  release_dir=$(prepare_base_release "$version")
  overlay_la64_artifacts "$release_dir"

  log "release-like directory: $release_dir"
  if [[ "$SKIP_INSTALL" -eq 0 ]]; then
    install_image "$release_dir"
  fi

  if [[ "$KEEP" -eq 0 ]]; then
    log "removing workdir: $WORKDIR"
    rm -rf "$WORKDIR"
  else
    log "kept workdir: $WORKDIR"
  fi
}

main
