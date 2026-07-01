#!/usr/bin/env bash
# Prepare a Ventoy build environment and optionally run common build steps.
#
# Typical use:
#   bash INSTALL/setup_build_env.sh --install-deps --download
#   bash INSTALL/setup_build_env.sh --grub-loongarch-native
#   bash INSTALL/setup_build_env.sh --all-in-one
#
# Notes:
# - Ventoy vendors GRUB source under GRUB2/MOD_SRC; GRUB2/grub-2.04.tar.xz is
#   still required by GRUB2/buildgrub.sh and is downloaded here.
# - On LoongArch64 hosts, --grub-loongarch-native builds only the native
#   loongarch64-efi GRUB tree needed for verification.
# - Full Ventoy packaging may still require project-provided prebuilt binaries
#   and cross toolchains for other architectures, matching DOC/BuildVentoyFromSource.txt.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
HOST_ARCH=$(uname -m)

DOWNLOAD=0
INSTALL_DEPS=0
EXTRACT_TOOLCHAINS=0
GRUB_LOONGARCH_NATIVE=0
ALL_IN_ONE=0
CI_MODE=0
PREFIX_OPT=/opt

log() { printf '\033[1;34m[ventoy-build-env]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ventoy-build-env][warn]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[ventoy-build-env][error]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: bash INSTALL/setup_build_env.sh [options]

Options:
  --install-deps              Install common build packages with the host package manager.
  --download                  Download Ventoy third-party source/tool archives.
  --extract-toolchains        Extract downloaded cross toolchains into /opt (requires sudo).
  --grub-loongarch-native     Build/install only native loongarch64-efi GRUB modules.
  --all-in-one                Run INSTALL/all_in_one.sh after preparation.
  --ci                        Pass CI to all_in_one.sh / ventoy_pack.sh style scripts.
  --prefix-opt DIR            Toolchain extraction prefix, default: /opt.
  -h, --help                  Show this help.

Common flows:
  # Prepare downloads/deps on a developer machine:
  bash INSTALL/setup_build_env.sh --install-deps --download

  # LoongArch64 validation machine: build only native GRUB baseline:
  bash INSTALL/setup_build_env.sh --download --grub-loongarch-native

  # Traditional full build, when all cross toolchains and binary inputs are ready:
  bash INSTALL/setup_build_env.sh --install-deps --download --extract-toolchains --all-in-one
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-deps) INSTALL_DEPS=1 ;;
    --download) DOWNLOAD=1 ;;
    --extract-toolchains) EXTRACT_TOOLCHAINS=1 ;;
    --grub-loongarch-native) GRUB_LOONGARCH_NATIVE=1 ;;
    --all-in-one) ALL_IN_ONE=1 ;;
    --ci) CI_MODE=1 ;;
    --prefix-opt) PREFIX_OPT=${2:?--prefix-opt requires a directory}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

sudo_if_needed() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

install_deps() {
  log "installing common build dependencies for host arch: $HOST_ARCH"

  if command -v apt-get >/dev/null 2>&1; then
    sudo_if_needed apt-get update
    sudo_if_needed apt-get install -y \
      build-essential gcc g++ make python3 python3-pip \
      autoconf automake autopoint gettext libtool flex bison help2man texinfo \
      wget curl ca-certificates tar xz-utils unzip zip dos2unix rsync \
      gdisk parted util-linux dosfstools exfatprogs mtools xorriso \
      libdevmapper-dev device-mapper qemu-system || true
  elif command -v oma >/dev/null 2>&1; then
    sudo_if_needed oma install -y \
      gcc g++ make python3 autoconf automake gettext libtool flex bison \
      wget curl tar xz unzip zip dos2unix rsync gdisk parted util-linux \
      dosfstools exfatprogs mtools xorriso device-mapper qemu || true
  elif command -v dnf >/dev/null 2>&1; then
    sudo_if_needed dnf install -y \
      gcc gcc-c++ make python3 autoconf automake gettext-devel libtool flex bison \
      wget curl tar xz unzip zip dos2unix rsync gdisk parted util-linux \
      dosfstools exfatprogs mtools xorriso device-mapper-devel qemu-system-* || true
  elif command -v yum >/dev/null 2>&1; then
    sudo_if_needed yum install -y \
      gcc gcc-c++ make python3 autoconf automake gettext-devel libtool flex bison \
      wget curl tar xz unzip zip dos2unix rsync gdisk parted util-linux \
      dosfstools mtools xorriso device-mapper-devel qemu-* || true
  else
    warn "no supported package manager found; install dependencies manually from DOC/BuildVentoyFromSource.txt"
  fi
}

download_file() {
  local url=$1
  local out=$2
  if [[ -s "$out" ]]; then
    log "already present: ${out#$REPO_ROOT/}"
    return
  fi
  log "downloading ${out#$REPO_ROOT/}"
  if [[ -w "$(dirname -- "$out")" || ( ! -e "$(dirname -- "$out")" && -w "$(dirname -- "$(dirname -- "$out")")" ) ]]; then
    mkdir -p "$(dirname -- "$out")"
    wget -O "$out" "$url"
  else
    sudo_if_needed mkdir -p "$(dirname -- "$out")"
    local tmp
    tmp=$(mktemp)
    wget -O "$tmp" "$url"
    sudo_if_needed mv "$tmp" "$out"
  fi
}

download_inputs() {
  need_cmd wget
  log "downloading third-party inputs"

  download_file "https://github.com/ventoy/vtoytoolchain/releases/download/1.0/dietlibc-0.34.tar.xz" \
    "$REPO_ROOT/DOC/dietlibc-0.34.tar.xz"
  download_file "https://github.com/ventoy/vtoytoolchain/releases/download/1.0/musl-1.2.1.tar.gz" \
    "$REPO_ROOT/DOC/musl-1.2.1.tar.gz"
  download_file "https://github.com/ventoy/vtoytoolchain/releases/download/1.0/grub-2.04.tar.xz" \
    "$REPO_ROOT/GRUB2/grub-2.04.tar.xz"
  download_file "https://codeload.github.com/tianocore/edk2/zip/edk2-stable201911" \
    "$REPO_ROOT/EDK2/edk2-edk2-stable201911.zip"
  download_file "https://codeload.github.com/relan/exfat/zip/v1.3.0" \
    "$REPO_ROOT/ExFAT/exfat-1.3.0.zip"
  download_file "https://codeload.github.com/libfuse/libfuse/zip/fuse-2.9.9" \
    "$REPO_ROOT/ExFAT/libfuse-fuse-2.9.9.zip"

  # Toolchain archives used by the original x86_64/CentOS-oriented build flow.
  download_file "https://releases.linaro.org/components/toolchain/binaries/7.4-2019.02/aarch64-linux-gnu/gcc-linaro-7.4.1-2019.02-x86_64_aarch64-linux-gnu.tar.xz" \
    "$PREFIX_OPT/gcc-linaro-7.4.1-2019.02-x86_64_aarch64-linux-gnu.tar.xz"
  download_file "https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs/aarch64--uclibc--stable-2020.08-1.tar.bz2" \
    "$PREFIX_OPT/aarch64--uclibc--stable-2020.08-1.tar.bz2"
  download_file "https://github.com/ventoy/vtoytoolchain/releases/download/1.0/mips-loongson-gcc7.3-2019.06-29-linux-gnu.tar.gz" \
    "$PREFIX_OPT/mips-loongson-gcc7.3-2019.06-29-linux-gnu.tar.gz"
  download_file "https://github.com/ventoy/musl-cross-make/releases/download/latest/output.tar.bz2" \
    "$PREFIX_OPT/output.tar.bz2"

  mkdir -p "$REPO_ROOT/LiveCD/ISO/EFI/boot"
  download_file "http://www.tinycorelinux.net/11.x/x86_64/release/distribution_files/vmlinuz64" \
    "$REPO_ROOT/LiveCD/ISO/EFI/boot/vmlinuz64"
  download_file "http://www.tinycorelinux.net/11.x/x86_64/release/distribution_files/corepure64.gz" \
    "$REPO_ROOT/LiveCD/ISO/EFI/boot/corepure64.gz"
  download_file "http://www.tinycorelinux.net/11.x/x86_64/release/distribution_files/modules64.gz" \
    "$REPO_ROOT/LiveCD/ISO/EFI/boot/modules64.gz"
}

extract_toolchains() {
  log "extracting cross toolchains into $PREFIX_OPT"
  sudo_if_needed tar xf "$PREFIX_OPT/gcc-linaro-7.4.1-2019.02-x86_64_aarch64-linux-gnu.tar.xz" -C "$PREFIX_OPT"
  sudo_if_needed tar xf "$PREFIX_OPT/aarch64--uclibc--stable-2020.08-1.tar.bz2" -C "$PREFIX_OPT"
  sudo_if_needed tar xf "$PREFIX_OPT/mips-loongson-gcc7.3-2019.06-29-linux-gnu.tar.gz" -C "$PREFIX_OPT"
  sudo_if_needed tar xf "$PREFIX_OPT/output.tar.bz2" -C "$PREFIX_OPT"
  if [[ -d "$PREFIX_OPT/output" && ! -e "$PREFIX_OPT/mips64el-linux-musl-gcc730" ]]; then
    sudo_if_needed mv "$PREFIX_OPT/output" "$PREFIX_OPT/mips64el-linux-musl-gcc730"
  fi
}

build_grub_loongarch_native() {
  [[ "$HOST_ARCH" == "loongarch64" ]] || die "--grub-loongarch-native requires host uname -m = loongarch64, got $HOST_ARCH"
  need_cmd gcc
  need_cmd make
  need_cmd tar
  [[ -f "$REPO_ROOT/GRUB2/grub-2.04.tar.xz" ]] || die "missing GRUB2/grub-2.04.tar.xz; run --download first"

  log "building native loongarch64-efi GRUB"
  cd "$REPO_ROOT/GRUB2"
  rm -rf SRC INSTALL NBP PXE
  mkdir -p SRC NBP PXE
  tar -xf grub-2.04.tar.xz -C SRC/
  cp -a MOD_SRC/grub-2.04 SRC/

  cd SRC/grub-2.04
  ./autogen.sh
  ./configure \
    --prefix="$REPO_ROOT/GRUB2/INSTALL" \
    --with-platform=efi \
    --disable-werror \
    CC="gcc -std=gnu17" \
    BUILD_CC="gcc -std=gnu17" \
    HOST_CC="gcc -std=gnu17" \
    TARGET_CC="gcc -std=gnu17" \
    TARGET_OBJCOPY=objcopy \
    TARGET_STRIP=strip \
    TARGET_NM=nm \
    TARGET_RANLIB=ranlib
  make -j"$(nproc)"
  make install

  log "syncing loongarch64 GRUB modules into INSTALL/grub/loongarch64-efi"
  cd "$REPO_ROOT"
  rm -rf INSTALL/grub/loongarch64-efi
  mkdir -p INSTALL/grub/loongarch64-efi
  find GRUB2/INSTALL/lib/grub/loongarch64-efi \
    -maxdepth 1 \( -name '*.mod' -o -name '*.lst' \) \
    -exec cp -a {} INSTALL/grub/loongarch64-efi/ \;
  while IFS= read -r -d '' f; do
    xz -f "$f"
    mv "$f.xz" "$f"
  done < <(find INSTALL/grub/loongarch64-efi -type f \( -name '*.mod' -o -name '*.lst' \) -print0)

  file INSTALL/grub/loongarch64-efi/normal.mod || true
  log "native loongarch64 GRUB build complete"
}

run_all_in_one() {
  log "running INSTALL/all_in_one.sh"
  cd "$REPO_ROOT/INSTALL"
  if [[ "$CI_MODE" -eq 1 ]]; then
    sh all_in_one.sh CI
  else
    sh all_in_one.sh
  fi
}

main() {
  log "repo: $REPO_ROOT"
  log "host: $HOST_ARCH"

  [[ "$INSTALL_DEPS" -eq 1 ]] && install_deps
  [[ "$DOWNLOAD" -eq 1 ]] && download_inputs
  [[ "$EXTRACT_TOOLCHAINS" -eq 1 ]] && extract_toolchains
  [[ "$GRUB_LOONGARCH_NATIVE" -eq 1 ]] && build_grub_loongarch_native
  [[ "$ALL_IN_ONE" -eq 1 ]] && run_all_in_one

  log "done"
}

main
