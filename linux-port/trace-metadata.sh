#!/bin/bash
# Complete the native-image metadata trace.
#
# Runs the port's driving checks under GraalVM's tracing agent, all merging into
# one config directory, so the metadata covers the paths the checks take --
# login, the chat list, sending a message and the emoji panel -- and not just a
# boot. The agent writes its files when the VM shuts down, so every check has to
# be allowed to finish: a killed run contributes nothing.
#
# check-tlstore.sh is here for a different reason: a driving run only ever takes
# the TLClassStore arms the server happens to send (two of nineteen), so that one
# exercises the rest on purpose. It is a --run-class check, which takes the agent
# option as a launcher argument instead of through PORT_EXTRA_JVM_ARGS.
#
# The checks are run in this order on purpose. check-tlstore.sh is seconds and
# needs no session, so it goes first; check-mtproto.sh then boots
# `run.sh --fresh`, which wipes the data dir, and the last three transplant the
# session back before they boot (transplant-session.sh).
#
# The config dir is wiped before the run unless --merge is given, so one command
# on a clean checkout produces the whole config and nothing else. The agent can
# only ever add to a config-merge-dir: merging today's trace into a config from
# before the dumper and registry work keeps every entry they removed, and each surviving
# entry is an image root the build then has to honour.
#
# Usage: linux-port/trace-metadata.sh [--config-dir DIR] [--only NAME]...
#                                     [--merge] [--baseline DIR]
#   --config-dir  where the agent writes its config; default out/ni-config
#   --only NAME   run only this check (tlstore|mtproto|chatlist|messages|emoji),
#                 may be repeated. Default: all of them, in order. A partial trace
#                 is not a usable config on its own, so --only needs --merge or
#                 its own --config-dir
#   --merge       add to what is already in the config dir instead of wiping it
#   --baseline    config dir to compare the result against; default
#                 out/ni-config-baseline-boot. A missing default is reported, not
#                 skipped in silence; a missing explicit one is an error
#
# Exits non-zero if any check fails or if the config dir did not end up complete.
# Writes out/trace-<name>.log per check and a <config-dir>.trace-stamp saying what
# produced the config.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

config_dir="$PORT_OUT/ni-config"
baseline_dir="$PORT_OUT/ni-config-baseline-boot"
only=()
merge=0
config_dir_given=0
baseline_given=0

while [ $# -gt 0 ]; do
	case "$1" in
	--config-dir) config_dir="$2"; config_dir_given=1; shift 2 ;;
	--baseline) baseline_dir="$2"; baseline_given=1; shift 2 ;;
	--only) only+=("$2"); shift 2 ;;
	--merge) merge=1; shift ;;
	*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done

if [ "${#only[@]}" -gt 0 ] && [ "$merge" = 0 ] && [ "$config_dir_given" = 0 ]; then
	echo "--only ${only[*]} would replace $config_dir with a partial config." >&2
	echo "Pass --merge to add to it, or --config-dir DIR to trace somewhere else." >&2
	exit 1
fi

all_names=(tlstore mtproto chatlist messages emoji)
names=("${all_names[@]}")
if [ "${#only[@]}" -gt 0 ]; then
	for want in "${only[@]}"; do
		printf '%s\n' "${all_names[@]}" | grep -qx "$want" || {
			echo "unknown check '$want' (${all_names[*]})" >&2; exit 1; }
	done
	names=("${only[@]}")
fi

# Checked before anything runs: a comparison that turns out to be impossible
# after five minutes of app runs is worse than no comparison at all. The default
# baseline is a kept boot-only trace, not something a script produces -- README.md
# has the one-run command that makes one.
baseline_note=""
if [ ! -d "$baseline_dir" ]; then
	[ "$baseline_given" = 0 ] || {
		echo "no baseline config dir at $baseline_dir" >&2; exit 1; }
	baseline_note="no baseline at $baseline_dir, so nothing to compare against"
	echo "note: $baseline_note (see README.md for how to record one)"
fi

# The agent library ships with GraalVM, so the checks have to run on GraalVM's
# libjvm.so. env.sh keeps an externally-set 21.x JAVA_HOME, and GraalVM CE 21.0.2
# reports 21.0.2, so exporting it here survives the env.sh every check sources.
[ -x "$GRAALVM_HOME/bin/java" ] || {
	echo "no java in \$GRAALVM_HOME ($GRAALVM_HOME); see check-graalvm.sh" >&2; exit 1; }
[ -f "$GRAALVM_HOME/lib/libnative-image-agent.so" ] || {
	echo "no tracing agent in $GRAALVM_HOME/lib; see check-graalvm.sh" >&2; exit 1; }
# env.sh keeps JAVA_HOME only while it reports 21.x, and silently replaces
# anything else with the port's OpenJDK -- which has no agent, so the run would
# die on an unresolvable -agentlib with nothing pointing at GRAALVM_HOME.
graal_java="$("$GRAALVM_HOME/bin/java" -version 2>&1)" || {
	echo "$GRAALVM_HOME/bin/java -version failed:" >&2; echo "$graal_java" >&2; exit 1; }
case "$graal_java" in
*'version "21.'*) ;;
*) echo "\$GRAALVM_HOME is not a JDK 21, so env.sh would drop it: $(head -1 <<<"$graal_java")" >&2
	echo "see check-graalvm.sh" >&2; exit 1 ;;
esac
export JAVA_HOME="$GRAALVM_HOME"
export PATH="$JAVA_HOME/bin:$PATH"

# The agent only ever adds to a config-merge-dir, so a stale directory silently
# keeps entries that are no longer traced. Start empty unless asked to merge.
stamp_file="${config_dir%/}.trace-stamp"
if [ "$merge" = 0 ] && [ -e "$config_dir" ]; then
	[ -d "$config_dir" ] || { echo "$config_dir is not a directory" >&2; exit 1; }
	# rm -rf on a caller-named path: only if everything in it is agent output.
	foreign="$(find "$config_dir" -mindepth 1 -maxdepth 1 \
		! -name '*-config.json' ! -name 'agent-extracted-predefined-classes' -print)"
	[ -z "$foreign" ] || {
		echo "refusing to wipe $config_dir: it holds files no trace wrote:" >&2
		printf '%s\n' "$foreign" >&2
		echo "(--merge to trace on top of it, --config-dir DIR to use another)" >&2
		exit 1
	}
	echo "wiping $config_dir (--merge to keep what is in it)"
	rm -rf "${config_dir:?}"
fi
# A stamp from an earlier run must not outlive the config it describes.
rm -f "$stamp_file"
# config-merge-dir needs the directory to exist; on a first trace it starts empty,
# which the agent accepts.
mkdir -p "$config_dir"
# The trace has to see what the image will do, not what HotSpot does. atlas gates
# View.overridesOnDraw's getDeclaredMethod on this property (atlas cfa73805), so
# without it the agent records ~137 onDraw entries the image never asks for.
agent_opt="-agentlib:native-image-agent=config-merge-dir=$config_dir"
image_opt="-Dorg.graalvm.nativeimage.imagecode=runtime"
# run.sh passes these on to the launcher; a --run-class check takes them as
# launcher arguments of its own (see the tlstore case below).
export PORT_EXTRA_JVM_ARGS="$agent_opt $image_opt"

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

# The launcher reaches a --run-class check's main() through FindClass, so the
# agent records the harness itself as a JNI root. The harness is not in the image,
# and native-image warns about every config entry it cannot resolve, so drop that
# one entry -- and only that one, by name -- as part of generating the config.
drop_harness() { # config-dir class-name
	python3 - "$1" "$2" <<-'PY'
		import json, os, sys
		d, harness = sys.argv[1], sys.argv[2]
		for name in ("jni-config.json", "reflect-config.json"):
		    p = os.path.join(d, name)
		    try:
		        with open(p) as f:
		            entries = json.load(f)
		    except FileNotFoundError:
		        continue
		    kept = [e for e in entries if e.get("name") != harness]
		    if len(kept) != len(entries):
		        with open(p, "w") as f:
		            json.dump(kept, f, indent=2)
		            f.write("\n")
		        print(f"  dropped the harness class {harness} from {name}")
	PY
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

echo "tracing into $config_dir with JAVA_HOME=$JAVA_HOME"
echo "agent option: $PORT_EXTRA_JVM_ARGS"
config_stats "$config_dir" "before:"

failed=()
for name in "${names[@]}"; do
	case "$name" in
	# No boot and no session: instantiates every TLClassStore arm (FR-4), which a
	# driving run cannot reach. Its launcher takes the agent option directly.
	tlstore)  run_check "$name" check-tlstore.sh -- -X "$agent_opt" -X "$image_opt" \
			&& drop_harness "$config_dir" TLClassStoreCheck \
			|| failed+=("$name") ;;
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
else
	echo "=== no baseline comparison: $baseline_note ==="
	echo
fi
config_stats "$config_dir" "merged:"

if [ "${#failed[@]}" -gt 0 ]; then
	echo
	echo "trace incomplete: ${#failed[@]} check(s) failed: ${failed[*]}" >&2
	echo "(their logs are in $PORT_OUT/trace-<name>.log)" >&2
	exit 1
fi

# Every check passing is not the same as the agent having written a config: it
# writes at VM shutdown, and an option that never reached the VM leaves the
# directory as it was while each check still exits 0.
missing=()
for f in reflect-config.json jni-config.json resource-config.json \
	proxy-config.json serialization-config.json predefined-classes-config.json
do
	[ -s "$config_dir/$f" ] || missing+=("$f")
done
if [ "${#missing[@]}" -gt 0 ]; then
	echo
	echo "the agent left $config_dir incomplete, missing: ${missing[*]}" >&2
	echo "(did every run really load the agent? grep 'jvm option' in the trace logs)" >&2
	exit 1
fi
reflect_n=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' \
	"$config_dir/reflect-config.json") || {
	echo "$config_dir/reflect-config.json does not parse" >&2; exit 1; }
[ "$reflect_n" -gt 0 ] || {
	echo "$config_dir/reflect-config.json is empty: nothing was traced" >&2; exit 1; }

merge_word=no; [ "$merge" = 0 ] || merge_word=yes
printf 'checks: %s\nmerged onto an existing config: %s\ndate: %s\njava: %s\noptions: %s\nreflect-config: %s classes\n' \
	"${names[*]}" "$merge_word" "$(date -Is)" "$JAVA_HOME" "$PORT_EXTRA_JVM_ARGS" "$reflect_n" \
	> "$stamp_file"

echo
if [ "${#names[@]}" = "${#all_names[@]}" ]; then
	echo "trace complete: ${names[*]} all passed, $reflect_n reflect classes in $config_dir"
else
	# Say so rather than let "trace complete" stand for a config that covers one
	# path: build-image.sh builds the image from whatever is in this directory.
	echo "partial trace complete: only ${names[*]} ran, so $config_dir is not the"
	echo "full profile ($reflect_n reflect classes); re-run without --only for that"
fi
echo "stamp: $stamp_file"
exit 0
