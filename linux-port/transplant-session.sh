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

# An app still writing its WAL would be copied mid-transaction.
if pgrep -f 'android-translation-layer' >/dev/null 2>&1; then
	echo "an android-translation-layer process is running; stop it first" >&2
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
