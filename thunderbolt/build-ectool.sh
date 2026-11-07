#!/usr/bin/env bash
# Build a standalone ChromiumOS `ectool` for EC console / Type-C diagnostics
# (typecstatus, typecdiscovery, typeccontrol, usbpdmuxinfo, console ...).
#
# Upstream main needs clang + platform2 libec/libchrome; release-R105 is the
# last pure-C ectool and builds with plain gcc. libusb is stubbed out
# (comm-usb-stub.c), so only the /dev/cros_ec transport is available.
#
#   ./thunderbolt/build-ectool.sh   -> ${XDG_CACHE_HOME:-~/.cache}/chromebook-fixes/ectool
#   sudo ~/.cache/chromebook-fixes/ectool console
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/chromebook-fixes"
BRANCH="${EC_BRANCH:-release-R105-14989.B-main}"
SRC="$CACHE/ec-src"
REPO="https://chromium.googlesource.com/chromiumos/platform/ec"

mkdir -p "$CACHE/gen"
if [ ! -d "$SRC/.git" ]; then
	git clone --depth 1 -b "$BRANCH" "$REPO" "$SRC"
else
	git -C "$SRC" fetch --depth 1 origin "$BRANCH"
	git -C "$SRC" reset --hard FETCH_HEAD
fi

cd "$SRC"
BOARD=host util/getversion.sh >"$CACHE/gen/ec_version.h"

SRCS=(
	util/ectool.c util/ectool_keyscan.c util/ectool_i2c.c
	util/ec_flash.c util/ec_panicinfo.c
	util/comm-host.c util/comm-dev.c util/comm-lpc.c util/comm-i2c.c
	util/misc_util.c
	util/lock/file_lock.c util/lock/gec_lock.c util/lock/android.c
	common/crc.c
	"$SCRIPT_DIR/comm-usb-stub.c"
)

# Flags mirror `make -n V=1 BOARD=host build/host/util/ectool`
gcc -O2 -std=gnu11 -w -D_GNU_SOURCE \
	-DBOARD=host -DBOARD_HOST= -DCHIP=host -DCHIP_HOST= -DCORE=host -DCORE_HOST= \
	-DCHROMIUM_EC= -DHOST_TOOLS_BUILD= -DPROJECT=ec -DBOARD_TASKFILE=ec.tasklist \
	-DOUTDIR=build/host/ -DFINAL_OUTDIR=build/host -DSECTION= -DTEST_ec= -DTEST_EC= \
	-I"$CACHE/gen" -I. -Iinclude -Iinclude/driver -Iutil -Iboard/host -Ichip/host \
	-Icore/host -Icore/host/include -Icommon -Ifuzz -Itest -Idriver -Ithird_party \
	-o "$CACHE/ectool" "${SRCS[@]}"

echo "Built: $CACHE/ectool ($(git rev-parse --short HEAD), branch $BRANCH)"
