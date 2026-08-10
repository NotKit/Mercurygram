#!/bin/bash
# Copies a logged-in ART/ATL data directory into the port's own.
#
# Both runtimes are atlas, so the layout is the same on both sides
# ($ANDROID_APP_DATA_DIR/<apk basename>_/{files,shared_prefs,...}) and the copy
# is all the "transplant" is: shared_prefs carry the account config, files/
# carries cache4.db and the per-account tgnet.dat with the auth keys.
#
# Usage: linux-port/transplant-session.sh [--from DIR] [--data-dir DIR] [--force]
#   --from      source data dir; default is the ART desktop run's
#               ~/.local/share/android_translation_layer/mercurygram-x64.apk_
#   --data-dir  the port's ANDROID_APP_DATA_DIR; default out/data (as run.sh)
#   --force     overwrite an existing session in the destination
#
# The source is only read. Do not run both apps at once: they would talk to
# Telegram with the same auth key from two processes.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

src="${PORT_SESSION_SRC:-$HOME/.local/share/android_translation_layer/mercurygram-x64.apk_}"
data_dir="${ANDROID_APP_DATA_DIR:-$PORT_OUT/data}"
force=0

while [ $# -gt 0 ]; do
	case "$1" in
	--from) src="$2"; shift 2 ;;
	--data-dir) data_dir="$2"; shift 2 ;;
	--force) force=1; shift ;;
	*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done

# The launcher appends <apk basename>_ to ANDROID_APP_DATA_DIR (atlas
# make_app_data_dir), so that, not the base, is what gets populated.
dst="$data_dir/$(basename "$PORT_OUT/app.apk")_"

[ -d "$src" ] || { echo "no source data dir at $src" >&2; exit 1; }
[ -f "$src/shared_prefs/userconfing.xml" ] || {
	echo "$src has no shared_prefs/userconfing.xml -- not a Telegram data dir" >&2
	exit 1
}

# A run of the app creates the same files, so "is there a session here already"
# is answered by the stamp this script leaves, not by the data dir's contents.
stamp="$dst/.port-transplant"
if [ -f "$stamp" ] && [ "$force" = 0 ]; then
	echo "$dst already holds a transplanted session:"
	sed 's/^/  /' "$stamp"
	echo "  (--force to copy again)"
	exit 0
fi

# An app still writing its WAL would be copied mid-transaction, and rsync over a
# live SQLite database is the corruption this guard exists to prevent. What
# matters is a process *holding* one of the two session trees, never how its
# command line was spelled: the same app is `$ATLAS_OUT/android-translation-layer-hotspot`,
# `./android-translation-layer-hotspot` from out/atlas, a symlink to either, or
# the click's `$PKG_ROOT/lib/...`, and only its open files are the same in all
# four. Unrelated atlas apps (the long-running atlas-camera2 test that made
# a later fix narrowed this) hold neither tree, so they still do not match.
# -m, not -f: the destination does not exist yet on a first transplant (mkdir -p
# is below), and -f prints nothing and exits 1 on a missing component, which
# under `set -e` would abort here with no message at all.
src_real="$(readlink -m "$src")"
dst_real="$(readlink -m "$dst")"
data_dir_real="$(readlink -m "$data_dir")"

busy=""
seen_pids=" "
note_busy() { # pid why
	case "$seen_pids" in *" $1 "*) return 0 ;; esac
	seen_pids+="$1 "
	local exe cmd
	# A process that exited between the scan and here is reported all the same:
	# an unreadable /proc entry is not a reason to drop a candidate silently.
	exe="$(readlink "/proc/$1/exe" 2>/dev/null || true)"
	cmd="$(tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null || true)"
	busy+="  pid $1 (${2}): ${exe:-<exited>} ${cmd:-}"$'\n'
}

# One find over /proc, not a readlink per descriptor: there are thousands.
# An open fd or a cwd inside either tree is the case that matters -- a live
# SQLite connection always holds its database open.
while read -r link target; do
	pid="${link#/proc/}"; pid="${pid%%/*}"
	[ "$pid" = "$$" ] && continue
	note_busy "$pid" "holds $target"
done < <(find /proc/[0-9]*/fd /proc/[0-9]*/cwd -maxdepth 1 \
	\( -lname "$dst_real" -o -lname "$dst_real/*" \
	   -o -lname "$src_real" -o -lname "$src_real/*" \) -printf '%p %l\n' 2>/dev/null || true)

# ... and an app of ours that has the destination as its data dir but has not
# opened anything in it yet. Restricted to the launcher by /proc/pid/exe: any
# shell that exported the variable would match otherwise. The source side gets no
# such check on purpose -- its data dir is the default one every atlas app shares.
while read -r environ; do
	pid="${environ#/proc/}"; pid="${pid%%/*}"
	[ "$pid" = "$$" ] && continue
	exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
	case "${exe##*/}" in
	android-translation-layer*) ;;
	*) continue ;;
	esac
	env_dir="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null |
		sed -n 's/^ANDROID_APP_DATA_DIR=//p' || true)"
	env_dir="${env_dir%%$'\n'*}"
	[ -n "$env_dir" ] || continue
	[ "$(readlink -f "$env_dir")" = "$data_dir_real" ] || continue
	note_busy "$pid" "ANDROID_APP_DATA_DIR=$env_dir"
done < <(grep -zlF "ANDROID_APP_DATA_DIR=" /proc/[0-9]*/environ 2>/dev/null || true)

if [ -n "$busy" ]; then
	echo "an app is using this session; stop it first:" >&2
	printf '%s' "$busy" >&2
	exit 1
fi

echo "copying $src"
echo "     -> $dst"
mkdir -p "$dst"
# lib/ holds the Android .so the ART build extracted from its apk; the port
# loads its own glibc one through -Dtmessages.native.path.
# extracted_assets/ and the SQLite -shm files are caches both sides rebuild.
# --delete-excluded so the destination is an exact mirror minus the excluded
# paths: a previous run's leftovers (extra account dirs, stale -shm) would
# otherwise survive next to the transplanted session.
rsync -a --delete --delete-excluded \
	--exclude 'lib/' \
	--exclude 'extracted_assets/' \
	--exclude '*.db-shm' \
	"$src/" "$dst/"

printf 'from: %s\ncopied: %s\n' "$src" "$(date -Is)" > "$stamp"

# --- verification -----------------------------------------------------------

for f in shared_prefs/userconfing.xml files/cache4.db files/account1/tgnet.dat; do
	[ -s "$dst/$f" ] || { echo "missing $dst/$f after the copy" >&2; exit 1; }
done

size=$(du -sh "$dst" | cut -f1)
dialogs=$(sqlite3 "file:$dst/files/cache4.db?immutable=1" \
	'select count(*) from dialogs' 2>/dev/null || echo "?")
echo "session in place: $size, $dialogs dialogs in cache4.db"
