#!/bin/bash
# Reproduce the class-load audit behind the shim: which runtime classes
# api-impl and the app reference that neither the JDK, the shim, nor the app
# classpath provides -- and who references them.
#
# Two passes, because they answer different questions:
#   jdeps   every unresolved reference, including ones in method bodies that may
#           never run. Referrers are printed, which is what the README lists.
#   load    every class loaded with initialization off, so only supertype and
#           interface failures show up: those break linking, not just a code path.
#
# Runtime classes (libcore, dalvik, android.system, android.icu, org.xmlpull,
# org.kxml2, org.json, org.apache.harmony) are the shim's business. Missing
# android.* framework classes are atlas's, and are listed separately.
#
# Usage: linux-port/shim/audit-shim.sh [--all]   (--all also lists framework gaps)
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/env.sh"

show_framework=0
[ "${1:-}" = "--all" ] && show_framework=1

RUNTIME='^(libcore|dalvik|android\.system|android\.icu|org\.xmlpull|org\.kxml2|org\.json|org\.apache\.harmony)\.'

CP="$ATLAS_OUT/api-impl.jar"
[ -f "$PORT_OUT/shim.jar" ] && CP="$CP:$PORT_OUT/shim.jar"
for jar in "$PORT_OUT"/classpath/*.jar; do
	[ -e "$jar" ] && CP="$CP:$jar"
done

targets=("$ATLAS_OUT/api-impl.jar")
for jar in "$PORT_OUT/classpath/mercurygram-app.jar" "$PORT_OUT/classpath/TMessagesProj.jar"; do
	[ -f "$jar" ] && targets+=("$jar")
done

refs="$(jdeps -v --ignore-missing-deps --multi-release 21 -cp "$CP" "${targets[@]}" |
	awk '/-> +[a-zA-Z0-9_.$]+ +not found/ {print $3"\t"$1}' | sort -u)"

echo "=== unresolved runtime classes (shim territory) ==="
printf '%s\n' "$refs" | grep -E "$RUNTIME" | awk -F'\t' '
	{ referrers[$1] = referrers[$1] " " $2; count[$1]++ }
	END { for (c in referrers) printf "%s (%d referrers):%s\n", c, count[c], referrers[c] }' |
	sort || echo "(none)"

echo
echo "=== classes that cannot link (missing supertype or interface) ==="
TOOLS_OUT="$PORT_OUT/tools"
mkdir -p "$TOOLS_OUT"
javac --release 21 -d "$TOOLS_OUT" "$PORT_DIR/tools/ClassLoadSweep.java"
java -cp "$TOOLS_OUT:$CP" ClassLoadSweep "${targets[@]}"

if [ "$show_framework" = 1 ]; then
	echo
	echo "=== unresolved framework classes (atlas territory) ==="
	printf '%s\n' "$refs" | grep -vE "$RUNTIME" | cut -f1 | sort -u
fi
