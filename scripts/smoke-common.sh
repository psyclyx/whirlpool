#!/bin/sh
set -eu

# Small, dependency-light helpers shared by the smoke entry points. Keep this
# file POSIX so it remains usable from a minimal Nix shell and from CI images.

smoke_root=${WHIRLPOOL_SOURCE_ROOT:-$(cd -- "$(dirname -- "$0")/.." && pwd)}

log() {
	printf '%s\n' "whirlpool-smoke: $*"
}

die() {
	log "FAIL: $*" >&2
	exit 1
}

skip() {
	log "SKIP: $*"
	exit 77
}

need_command() {
	command -v "$1" >/dev/null 2>&1 || die "required command '$1' was not found"
}

run_in_root() {
	(cd -- "$smoke_root" && "$@")
}

run_logged() {
	log "+ $*"
	"$@"
}
