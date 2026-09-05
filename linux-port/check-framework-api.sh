#!/bin/bash
# Reports framework methods and fields the app names but atlas does not have.
#
# A missing class fails at load and the existing checks catch it; a missing
# *method* fails only when the line runs, as a NoSuchMethodError. On the call
# path that meant VoIPService.onCreate died halfway through starting a call —
# and because an Error is not an Exception, the app's own catch did not stop it
# killing the process. Reading the constant pool finds the whole set at once
# instead of one per build-install-press-the-button round trip.
#
# Scans the call stack by default (that is where the gaps were); pass package
# paths to widen it, e.g. 'org/telegram/messenger/camera'.
#
# Usage: linux-port/check-framework-api.sh [PACKAGE_PATH ...]
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

packages=("$@")
[ ${#packages[@]} -gt 0 ] || packages=(
	org/telegram/messenger/voip
	org/telegram/ui/Components/voip
	org/webrtc
)

app_jar="$PORT_OUT/classpath/TMessagesProj.jar"
[ -f "$app_jar" ] || { echo "no $app_jar (run build-classpath.sh)" >&2; exit 1; }
[ -f "$ATLAS_OUT/artifacts.env" ] || { echo "no $ATLAS_OUT/artifacts.env (run build-atlas.sh)" >&2; exit 1; }
[ -f "$PORT_OUT/shim.jar" ] || { echo "no $PORT_OUT/shim.jar (run build-shim.sh)" >&2; exit 1; }
source "$ATLAS_OUT/artifacts.env"

out="$PORT_OUT/framework-api-check"
rm -rf "$out"
mkdir -p "$out/cls"

# The scanner reads class files, so the app classes have to be on disk.
patterns=()
for p in "${packages[@]}"; do patterns+=("$p/*"); done
unzip -q -o "$app_jar" "${patterns[@]}" -d "$out/cls"

"$JAVA_HOME/bin/javac" -nowarn -d "$out" "$PORT_DIR/tools/FrameworkApiCheck.java"

dirs=()
for p in "${packages[@]}"; do [ -d "$out/cls/$p" ] && dirs+=("$out/cls/$p"); done
[ ${#dirs[@]} -gt 0 ] || { echo "no classes matched: ${packages[*]}" >&2; exit 1; }

# Resolution happens against this class path, so it is the framework the port
# actually runs: atlas plus the shim.
report="$("$JAVA_HOME/bin/java" -cp "$out:$ATLAS_API_IMPL_JAR:$PORT_OUT/shim.jar" \
	FrameworkApiCheck "${dirs[@]}")"
echo "$report"

# Known-unreachable, deliberately not implemented in atlas: the telecom call
# path is behind VoIPService.USE_CONNECTION_SERVICE, a device whitelist this
# port does not match, and the rest is screen capture and Wi-Fi Direct.
missing="$(grep -E '^MISSING' <<<"$report" |
	grep -vE 'android\.telecom\.|android\.net\.wifi\.p2p\.|AudioPlaybackCaptureConfiguration' || true)"

if [ -n "$missing" ]; then
	echo
	echo "framework API check: $(wc -l <<<"$missing") reachable gap(s) above" >&2
	echo "add them in \$ATLAS_DIR (linux-port/CLAUDE.md), not here" >&2
	exit 1
fi

echo "framework API check: passed (only the deliberately skipped entries remain)"
