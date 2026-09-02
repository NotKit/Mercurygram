#!/bin/bash
# One command for the Ubuntu Touch click of the OpenJDK port:
#
#   linux-port/click/make-click.sh
#
# It stages the arm64 inputs that come from outside this repository (the build
# container only sees the repository itself), then runs clickable's cross build.
# The arch-independent halves must already exist — linux-port/build-all.sh
# produces them, and this checks rather than guesses.
#
# Anything after -- goes to clickable (e.g. -- --verbose).
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/env.sh"

# Only what the container cannot produce itself. Not shim.jar: build.sh runs
# build-shim.sh inside the container against the arm64 api-impl.jar and ships
# that build, so a host-side one is never consumed -- and demanding it would
# mean building atlas on the host just to satisfy the check.
for f in "$PORT_OUT/app.apk" "$PORT_OUT/classpath"; do
	[ -e "$f" ] || {
		echo "missing $f: run linux-port/build-classpath.sh first" >&2
		exit 1
	}
done

"$PORT_DIR/click/stage-prebuilt.sh"

extra=()
[ "${1:-}" = "--" ] && { shift; extra=("$@"); }

cd "$REPO_DIR"
clickable build --arch arm64 --skip-review "${extra[@]+"${extra[@]}"}"

echo
echo "built:"
find "$PORT_OUT/click" -name '*.click' -printf '  %p (%s bytes)\n' 2>/dev/null || true
echo
# hostname only: clickable prepends phablet@ itself, and phablet@phablet@host
# fails with a bare "Permission denied (publickey)"
echo "install it with:  clickable install --ssh <device>"
