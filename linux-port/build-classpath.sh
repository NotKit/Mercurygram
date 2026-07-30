#!/bin/bash
# Build the app's HotSpot classpath and the matching APK.
#
# Drives the Gradle jarForLinuxPort task, which jars AGP's javac output instead
# of dexing it, then smoke-tests the result with linux-port/tools/PortClassCheck.
#
# Usage: linux-port/build-classpath.sh [--clean]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

CLASSPATH_DIR="$PORT_OUT/classpath"
APK="$PORT_OUT/app.apk"

# Format is X.Y.Z.M; gradle/mg-version.gradle refuses to configure without it.
MG_BUILD_TAG="${MG_BUILD_TAG:-$(sed -n 's/^APP_VERSION_NAME=//p' "$REPO_DIR/gradle.properties").1}"

# TMessagesProj/build.gradle reads ./API_KEYS eagerly at configure time. The port
# only needs the file to exist to build; a real APP_ID/APP_HASH pair is needed
# before login works, so export them and re-run to bake real keys in.
if [ ! -s "$REPO_DIR/API_KEYS" ]; then
	printf 'APP_ID = %s\nAPP_HASH = %s\n' "${APP_ID:-0}" "${APP_HASH:-0}" \
		> "$REPO_DIR/API_KEYS"
	if [ -z "${APP_ID:-}" ]; then
		echo "warning: wrote a dummy $REPO_DIR/API_KEYS; MTProto login needs real" \
			"keys (export APP_ID / APP_HASH and re-run)" >&2
	fi
fi

# -PlinuxPort skips the NDK build; the port has its own libtmessages.so.
gradle_port() {
	(cd "$REPO_DIR" && ./gradlew -PlinuxPort "-PMG_BUILD_TAG=$MG_BUILD_TAG" "$@")
}

# clean gets its own invocation: Gradle does not order it against the tasks that
# repopulate the same build dir.
if [ "${1:-}" = "--clean" ]; then
	rm -rf "$CLASSPATH_DIR" "$APK"
	gradle_port :TMessagesProj:clean :TMessagesProj_App:clean
fi

gradle_port :TMessagesProj_App:jarForLinuxPort

# --- verification -----------------------------------------------------------

for jar in mercurygram-app.jar mercurygram-res.jar TMessagesProj.jar; do
	[ -s "$CLASSPATH_DIR/$jar" ] || { echo "missing $CLASSPATH_DIR/$jar" >&2; exit 1; }
done

jar_count=$(find "$CLASSPATH_DIR" -maxdepth 1 -name '*.jar' | wc -l)
[ "$jar_count" -ge 50 ] || { echo "only $jar_count jars in $CLASSPATH_DIR" >&2; exit 1; }

[ -s "$APK" ] || { echo "missing $APK" >&2; exit 1; }
apk_listing=$(unzip -l "$APK")
for entry in AndroidManifest.xml resources.arsc assets/; do
	grep -q "$entry" <<<"$apk_listing" || { echo "$APK has no $entry" >&2; exit 1; }
done

# Smoke test: the classes the launcher and check-native-loader.sh name must resolve off the
# classpath alone. Static initializers stay off (they reach into android.* / JNI),
# except for the R class, where a zero id would mean we picked up a compile-time
# stub instead of the linked resource table. Classes that extend android.*
# directly can only resolve once build-atlas.sh adds the atlas framework jar.
CHECK_DIR="$PORT_OUT/tools"
mkdir -p "$CHECK_DIR"
"$JAVA_HOME/bin/javac" -d "$CHECK_DIR" "$PORT_DIR/tools/PortClassCheck.java"

"$JAVA_HOME/bin/java" -cp "$CHECK_DIR:$CLASSPATH_DIR/*" PortClassCheck \
	org.telegram.messenger.Utilities \
	org.telegram.messenger.NativeLoader \
	org.telegram.messenger.AndroidUtilities \
	org.telegram.messenger.DispatchQueue \
	org.telegram.tgnet.ConnectionsManager \
	org.telegram.SQLite.SQLiteDatabase \
	org.telegram.messenger.regular.BuildConfig \
	'org.telegram.messenger.R$string#AppName' \
	--needs-android \
	org.telegram.messenger.ApplicationLoader \
	org.telegram.ui.LaunchActivity \
	org.telegram.ui.IntroActivity

echo "classpath ready: $jar_count jars in $CLASSPATH_DIR, apk at $APK"
