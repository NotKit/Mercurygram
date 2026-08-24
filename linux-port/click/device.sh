#!/bin/bash
# Drive the installed click on an Ubuntu Touch device over ssh:
#
#   click/device.sh run [--no-gpu] [--dpi N] [-- <extra launcher args>]
#   click/device.sh stop
#   click/device.sh shot out/screenshots/foo.png
#   click/device.sh log [journalctl args]
#
# $PORT_DEVICE picks the host (default oneplus11); the user is always phablet.
# Reached over Tailscale DNS, so the name is not in ~/.ssh/config.
set -euo pipefail
source "$(dirname "$0")/../env.sh"

DEVICE="${PORT_DEVICE:-oneplus11}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 "phablet@$DEVICE")
PKG=mercurygram-jvm.nekit
PKG_ROOT="/opt/click.ubuntu.com/$PKG/current"
# Lomiri's session runtime dir; the click's run.sh finds the wayland socket in it.
RUNDIR='/run/user/$(id -u)'

usage() { sed -n '2,9p' "$0" >&2; exit 2; }

dev_run() {
	local nogpu="" dpi="" args=()
	while [ $# -gt 0 ]; do
		case "$1" in
		--no-gpu) nogpu="MERCURYGRAM_NO_GPU=1"; shift ;;
		# An explicit density, for comparing against another runtime's scale.
		# GRID_UNIT_PX below can only say multiples of 20 dpi, and this overrides
		# it outright ($ATL_DENSITY_DPI in the environment does the same).
		--dpi) dpi="ATL_DENSITY_DPI=$2"; shift 2 ;;
		--) shift; args=("$@"); break ;;
		*) usage ;;
		esac
	done
	[ -n "$dpi" ] || [ -z "${ATL_DENSITY_DPI:-}" ] || dpi="ATL_DENSITY_DPI=$ATL_DENSITY_DPI"
	# GRID_UNIT_PX comes from Lomiri's own environment: atlas derives the display
	# density from it, and started from ssh without it the app runs at density 1,
	# which is not what the phone shows.
	# setsid + nohup: the launcher must outlive the ssh session, and it ignores
	# SIGTERM (linux-port/CLAUDE.md), so stop below has to use SIGKILL anyway.
	"${SSH[@]}" "export XDG_RUNTIME_DIR=$RUNDIR; \
		export \$(tr '\\0' '\\n' < /proc/\$(pgrep -x lomiri | head -1)/environ | grep '^GRID_UNIT_PX='); \
		$nogpu $dpi setsid nohup $PKG_ROOT/run.sh ${args[*]:-} \
		>/tmp/mercurygram-jvm.log 2>&1 < /dev/null & sleep 1; echo started"
}

dev_stop() {
	# The launcher ignores SIGTERM; anchor the pattern so this does not match the
	# shell ssh started it from. Lomiri starts the versioned path from the desktop
	# file while run above goes through 'current', so match either.
	"${SSH[@]}" "pkill -9 -f '^/opt/click.ubuntu.com/$PKG/[^/]+/lib/android-translation-layer-hotspot ' || true"
}

# One frame off the compositor. mirscreencast writes raw RGBA at the panel's
# size, and the first frame is often stale, so take two and keep the last.
dev_shot() {
	local out="${1:?usage: device.sh shot FILE.png}" size w h bytes
	mkdir -p "$(dirname "$out")"
	size="$("${SSH[@]}" "MIR_SOCKET=$RUNDIR/mir_socket mirscreencast --query" |
		sed -n 's/^Output size: \([0-9]*\)x\([0-9]*\)/\1 \2/p')"
	read -r w h <<<"$size"
	[ -n "${w:-}" ] && [ -n "${h:-}" ] || { echo "device.sh: no output size from mirscreencast" >&2; return 1; }
	bytes=$((w * h * 4))
	"${SSH[@]}" "MIR_SOCKET=$RUNDIR/mir_socket mirscreencast -n 2 --stdout 2>/dev/null" |
		tail -c "$bytes" | convert -size "${w}x${h}" -depth 8 rgba:- "$out"
	echo "$out (${w}x${h})"
}

dev_log() {
	"${SSH[@]}" "tail -n ${1:-200} /tmp/mercurygram-jvm.log"
}

cmd="${1:-}"; shift || usage
case "$cmd" in
run) dev_run "$@" ;;
stop) dev_stop ;;
shot) dev_shot "$@" ;;
log) dev_log "$@" ;;
*) usage ;;
esac
