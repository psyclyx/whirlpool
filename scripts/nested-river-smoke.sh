#!/bin/sh
set -eu

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/smoke-common.sh"

allow_skip=false
if [ "${1:-}" = "--allow-skip" ]; then
	allow_skip=true
	shift
fi
[ "$#" -eq 0 ] || die "usage: $0 [--allow-skip]"

"$script_dir/compositor-free-smoke.sh"
for command_name in river timeout; do
	command -v "$command_name" >/dev/null 2>&1 || {
		if $allow_skip; then skip "'$command_name' is unavailable"; fi
		die "'$command_name' is required for nested smoke"
	}
done
[ -n "${WAYLAND_DISPLAY:-}" ] || {
	if $allow_skip; then skip "WAYLAND_DISPLAY is unset"; fi
	die "WAYLAND_DISPLAY is unset; nested River needs a parent Wayland session"
}

whirlpool_bin=${WHIRLPOOL_BIN:-$smoke_root/zig-out/bin/whirlpool}
[ -x "$whirlpool_bin" ] || die "Whirlpool executable not found: $whirlpool_bin"
config=${WHIRLPOOL_CONFIG:-$smoke_root/config/whirlpool.lua}
log_file=${WHIRLPOOL_NESTED_LOG:-${TMPDIR:-/tmp}/whirlpool-river-smoke-$$.log}

log "starting nested River with Whirlpool as its init (log=$log_file)"
set +e
WLR_BACKENDS=wayland WLR_LIBINPUT_NO_DEVICES=1 \
	timeout "${WHIRLPOOL_CLIENT_TIMEOUT:-5}s" river -c \
	"exec $whirlpool_bin river --config \"$config\"" >"$log_file" 2>&1
status=$?
set -e
[ "$status" -eq 124 ] || die "nested River exited early (exit $status; log: $log_file)"
grep -q "Loaded Whirlpool config:" "$log_file" || die "sample config did not load (log: $log_file)"
grep -q "River host connected" "$log_file" || die "Whirlpool did not connect (log: $log_file)"
grep -q "River shell surface ready" "$log_file" || die "River shell surface was not initialized (log: $log_file)"
grep -q "River shell surface committed its first frame" "$log_file" || die "River shell surface did not present (log: $log_file)"
if grep -qE "error:|cleanup failed|Segmentation fault" "$log_file"; then
	die "nested run logged an error (log: $log_file)"
fi
log "PASS: nested River loaded the sample config, presented its shell surface, and stayed connected"
