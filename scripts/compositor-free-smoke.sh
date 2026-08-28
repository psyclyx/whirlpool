#!/bin/sh
set -eu

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/smoke-common.sh"

[ "$#" -eq 0 ] || die "usage: $0"
need_command zig
need_command mktemp
need_command rm
zig_cache=$(mktemp -d "${TMPDIR:-/tmp}/whirlpool-zig-cache.XXXXXX")
trap 'rm -rf -- "$zig_cache"' EXIT HUP INT TERM
log "running deterministic compositor-free build and tests"
run_in_root run_logged zig build --global-cache-dir "$zig_cache" test
run_in_root run_logged zig build --global-cache-dir "$zig_cache" check
log "PASS: deterministic compositor-free smoke"
