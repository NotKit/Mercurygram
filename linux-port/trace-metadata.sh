#!/bin/bash
# Complete the native-image metadata trace.
#
# Runs the port's four driving checks under GraalVM's tracing agent, all merging
# into one config directory, so the metadata covers the paths the checks take --
# login, the chat list, sending a message and the emoji panel -- and not just a
# boot. The agent writes its files when the VM shuts down, so every check has to
# be allowed to finish: a killed run contributes nothing.
#
# The checks are run in this order on purpose. check-mtproto.sh boots
# `run.sh --fresh`, which wipes the data dir; the other three transplant the
# session back before they boot (transplant-session.sh).
#
# Usage: linux-port/trace-metadata.sh [--config-dir DIR] [--only NAME]...
#                                     [--baseline DIR]
#   --config-dir  where the agent merges its config; default out/ni-config
#   --only NAME   run only this check (mtproto|chatlist|messages|emoji), may be
#                 repeated. Default: all four, in order
#   --baseline    config dir to compare the result against; default
#                 out/ni-config-baseline-boot if it exists
#
# Exits non-zero if any check fails. Writes out/trace-<name>.log per check.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

config_dir="$PORT_OUT/ni-config"
baseline_dir="$PORT_OUT/ni-config-baseline-boot"
only=()

while [ $# -gt 0 ]; do
	case "$1" in
	--config-dir) config_dir="$2"; shift 2 ;;
	--baseline) baseline_dir="$2"; shift 2 ;;
	--only) only+=("$2"); shift 2 ;;
	*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done

# The agent library ships with GraalVM, so the checks have to run on GraalVM's
# libjvm.so. env.sh keeps an externally-set 21.x JAVA_HOME, and GraalVM CE 21.0.2
# reports 21.0.2, so exporting it here survives the env.sh every check sources.
[ -x "$GRAALVM_HOME/bin/java" ] || {
	echo "no java in \$GRAALVM_HOME ($GRAALVM_HOME); see check-graalvm.sh" >&2; exit 1; }
[ -f "$GRAALVM_HOME/lib/libnative-image-agent.so" ] || {
	echo "no tracing agent in $GRAALVM_HOME/lib; see check-graalvm.sh" >&2; exit 1; }
export JAVA_HOME="$GRAALVM_HOME"
export PATH="$JAVA_HOME/bin:$PATH"

# config-merge-dir needs the directory to exist; on a first trace it starts empty,
# which the agent accepts.
mkdir -p "$config_dir"
# The trace has to see what the image will do, not what HotSpot does. atlas gates
# View.overridesOnDraw's getDeclaredMethod on this property (atlas cfa73805), so
# without it the agent records ~137 onDraw entries the image never asks for.
export PORT_EXTRA_JVM_ARGS="-agentlib:native-image-agent=config-merge-dir=$config_dir \
-Dorg.graalvm.nativeimage.imagecode=runtime"

launcher="$ATLAS_OUT/android-translation-layer-hotspot"

# Timeouts are upper bounds: every check but check-mtproto.sh ends its run through
# run.sh --stop-file as soon as it is done. They are sized for a session that has
# to catch up on updates first (the checks wait up to 420s for `isUpdating`), plus
# the agent's own slowdown.
run_check() { # name script args...
	local name="$1" script="$2"; shift 2
	local log="$PORT_OUT/trace-$name.log" started status=0
	echo
	echo "=== $name: $script $* ==="
	started=$(date +%s)
	# set +e, not `|| true`: `||` runs another command and that command's status
	# is what PIPESTATUS then holds, so the check would always look successful.
	set +e
	"$PORT_DIR/$script" "$@" 2>&1 | tee "$log"
	status=${PIPESTATUS[0]}
	set -e
	echo "--- $name exited $status after $(( $(date +%s) - started ))s"
	# A check that failed part-way can leave the launcher behind; the next one
	# would then fight it for the account and the display.
	pkill -9 -f "^$launcher " 2>/dev/null || true
	sleep 2
	config_stats "$config_dir" "  after $name:"
	return "$status"
}

# Counts, not diffs: this is what goes into BRINGUP_NOTES.md and what tells you
# at a glance whether a check contributed anything.
config_stats() { # dir prefix
	python3 - "$1" "$2" <<-'PY'
		import json, os, sys
		d, prefix = sys.argv[1], sys.argv[2]
		def load(name):
		    p = os.path.join(d, name)
		    try:
		        with open(p) as f:
		            return json.load(f), os.path.getsize(p)
		    except FileNotFoundError:
		        return None, 0
		refl, refl_size = load("reflect-config.json")
		jni, jni_size = load("jni-config.json")
		res, _ = load("resource-config.json")
		proxy, _ = load("proxy-config.json")
		ser, _ = load("serialization-config.json")
		res_n = 0
		if res:
		    r = res.get("resources", res)
		    if isinstance(r, dict):
		        res_n = len(r.get("includes", [])) + len(r.get("excludes", []))
		    else:
		        res_n = len(r)
		    res_n += len(res.get("bundles", [])) if isinstance(res, dict) else 0
		def n(x):
		    return len(x) if x is not None else 0
		print(f"{prefix} reflect {n(refl)} classes ({refl_size} B), "
		      f"jni {n(jni)} classes ({jni_size} B), resource {res_n} entries, "
		      f"proxy {n(proxy)}, serialization "
		      f"{sum(len(v) for v in ser.values()) if isinstance(ser, dict) else n(ser)}")
	PY
}

# What the merged config gained over the boot-only baseline, by name: the
# acceptance criterion is that login, message send and emoji classes are in the
# merged config and not in the baseline.
config_diff() { # baseline merged
	python3 - "$1" "$2" <<-'PY'
		import json, os, sys
		def names(d):
		    p = os.path.join(d, "reflect-config.json")
		    try:
		        with open(p) as f:
		            return {e["name"] for e in json.load(f)}
		    except FileNotFoundError:
		        return set()
		base, merged = names(sys.argv[1]), names(sys.argv[2])
		added = sorted(merged - base)
		removed = sorted(base - merged)
		print(f"reflect-config: {len(base)} -> {len(merged)} classes "
		      f"(+{len(added)}, -{len(removed)})")
		for c in added:
		    print(f"  + {c}")
		for c in removed:
		    print(f"  - {c}")
	PY
}

names=(mtproto chatlist messages emoji)
if [ "${#only[@]}" -gt 0 ]; then
	for want in "${only[@]}"; do
		printf '%s\n' "${names[@]}" | grep -qx "$want" || {
			echo "unknown check '$want' (${names[*]})" >&2; exit 1; }
	done
	names=("${only[@]}")
fi

echo "tracing into $config_dir with JAVA_HOME=$JAVA_HOME"
echo "agent option: $PORT_EXTRA_JVM_ARGS"
config_stats "$config_dir" "before:"

failed=()
for name in "${names[@]}"; do
	case "$name" in
	# --fresh, no session: this is the login path (intro -> phone -> sendCode).
	mtproto)  run_check "$name" check-mtproto.sh  --seconds 150 || failed+=("$name") ;;
	chatlist) run_check "$name" check-chatlist.sh --seconds 600 || failed+=("$name") ;;
	# The incoming half waits on the account's own traffic, so --seconds has to
	# leave room for --incoming-seconds on top of the update catch-up.
	messages) run_check "$name" check-messages.sh --seconds 900 --incoming-seconds 300 \
		|| failed+=("$name") ;;
	emoji)    run_check "$name" check-emoji.sh    --seconds 700 || failed+=("$name") ;;
	esac
done

echo
if [ -d "$baseline_dir" ]; then
	echo "=== against the baseline in $baseline_dir ==="
	config_diff "$baseline_dir" "$config_dir"
	echo
fi
config_stats "$config_dir" "merged:"

if [ "${#failed[@]}" -gt 0 ]; then
	echo
	echo "trace incomplete: ${#failed[@]} check(s) failed: ${failed[*]}" >&2
	echo "(their logs are in $PORT_OUT/trace-<name>.log)" >&2
	exit 1
fi

echo
echo "trace complete: ${names[*]} all passed, config merged into $config_dir"
exit 0
