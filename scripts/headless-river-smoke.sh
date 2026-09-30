#!/bin/sh
# End-to-end check on a nested, headless River with three 1280x720 outputs.
# Drives real key bindings with wtype, screenshots with grim, and asserts on
# pixels: windows moved between tags keep their decorations, focus-output
# visits every output in order, and asking for a tag another output shows
# only moves focus there.
set -eu

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_dir/smoke-common.sh"

term=${SMOKE_TERMINAL:-alacritty}

if [ "${1:-}" = "--inner" ]; then
	shots=$2
	whirlpool_bin=${WHIRLPOOL_BIN:-$smoke_root/zig-out/bin/whirlpool}
	config=${SMOKE_WHIRLPOOL_CONFIG:-$smoke_root/config/whirlpool.lua}
	# WHIRLPOOL_CONFIG in the environment (e.g. a session's) overrides --config, so set it.
	export WHIRLPOOL_CONFIG="$config"
	# Keep the nested session's saved state away from the real session's.
	export WHIRLPOOL_STATE_PREFIX="$shots/state"
	export LUA_PATH="$smoke_root/lua/?.lua;$smoke_root/lua/?/init.lua;$smoke_root/lua/?/?.lua;;"
	"$whirlpool_bin" river --config "$config" >"$shots/whirlpool.log" 2>&1 &
	whirlpool_pid=$!
	sleep 2
	key() { wtype "$@"; sleep 0.6; }
	$term --title A >/dev/null 2>&1 &
	sleep 1.6
	key -M logo -M shift -k 2 -m shift -m logo # A -> tag 2, shown on output 2
	$term --title B >/dev/null 2>&1 &
	sleep 1.6
	$term --title C >/dev/null 2>&1 &
	sleep 1.6
	key -M logo -M shift -k 3 -m shift -m logo # C -> tag 3, shown on output 3
	key -M logo -k 1 -m logo                   # focus B on output 1
	grim "$shots/placed.png"
	for n in 1 2 3; do
		key -M logo -k period -m logo
		grim "$shots/next$n.png"
	done
	for n in 1 2 3; do
		key -M logo -k comma -m logo
		grim "$shots/prev$n.png"
	done
	key -M logo -k 3 -m logo # tag 3 is shown on output 3: focus moves, nothing else
	grim "$shots/tag.png"
	key -M logo -k 2 -m logo # focus A on output 2
	key -M logo -M shift -k 1 -m shift -m logo # A -> tag 1: output 2 is now empty
	key -M logo -k 2 -m logo # tag 2 is shown on the empty output 2: focus the monitor
	grim "$shots/empty.png"
	$term --title D >/dev/null 2>&1 &
	sleep 1.6
	grim "$shots/opened.png"
	for step in right1:l right2:l left1:h left2:h; do
		key -M logo -k "${step#*:}" -m logo
		grim "$shots/${step%:*}.png"
	done
	key -M logo -k 4 -m logo # tag 4 is shown nowhere: this monitor now holds no windows
	grim "$shots/hidden.png"
	key -M logo -k 1 -m logo # bring a populated tag back before restarting
	grim "$shots/before.png"
	# Restart the window manager: River keeps the windows, whirlpool must adopt them.
	kill "$whirlpool_pid"
	wait "$whirlpool_pid" 2>/dev/null || true
	"$whirlpool_bin" river --config "$config" >"$shots/whirlpool2.log" 2>&1 &
	sleep 3
	grim "$shots/after.png"
	touch "$shots/done"
	exit 0
fi

for command_name in river wtype grim magick "$term"; do
	command -v "$command_name" >/dev/null 2>&1 || skip "'$command_name' is unavailable"
done
whirlpool_bin=${WHIRLPOOL_BIN:-$smoke_root/zig-out/bin/whirlpool}
[ -x "$whirlpool_bin" ] || die "Whirlpool executable not found: $whirlpool_bin"

shots=$(mktemp -d "${TMPDIR:-/tmp}/whirlpool-headless-XXXXXX")
log "screenshots and logs in $shots"
# River stays up after its init script exits, so wait for the script to say it is
# done (or a generous limit) and then stop it, rather than waiting out a timeout.
WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=3 WLR_LIBINPUT_NO_DEVICES=1 \
	river -c "$0 --inner $shots" >"$shots/river.log" 2>&1 &
river_pid=$!
waited=0
while [ ! -f "$shots/done" ] && [ "$waited" -lt 150 ] && kill -0 "$river_pid" 2>/dev/null; do
	sleep 1
	waited=$((waited + 1))
done
kill "$river_pid" 2>/dev/null || true
wait "$river_pid" 2>/dev/null || true

pixel() { magick "$shots/$1.png" -format "%[pixel:p{$2}]" info:; }

# Outputs are 1280 wide; a window's left border sits 6px in, its title bar
# is drawn above it.
focused_output() { # shot -> 0-based index of the output whose window has the white border
	for index in 0 1 2; do
		[ "$(pixel "$1" "$((index * 1280 + 6)),200")" = "srgb(255,255,255)" ] && {
			echo "$index"
			return
		}
	done
	echo none
}
expect_focus() { # shot expected-index description
	actual=$(focused_output "$1")
	[ "$actual" = "$2" ] || die "$3: focus is on output $actual in $1.png, expected $2 (see $shots)"
}

for index in 0 1 2; do
	[ "$(pixel placed "$((index * 1280 + 100)),10")" != "srgb(0,0,0)" ] ||
		die "window on output $((index + 1)) has no decoration in placed.png (see $shots)"
done
expect_focus placed 0 "after focusing tag 1"
expect_focus next1 1 "focus-output-next from output 1"
expect_focus next2 2 "focus-output-next from output 2"
expect_focus next3 0 "focus-output-next wraps to output 1"
expect_focus prev1 2 "focus-output-prev wraps to output 3"
expect_focus prev2 1 "focus-output-prev from output 3"
expect_focus prev3 0 "focus-output-prev from output 2"
expect_focus tag 2 "focus-tag for a tag shown on output 3"
for index in 0 1 2; do
	[ "$(pixel tag "$((index * 1280 + 100)),10")" != "srgb(0,0,0)" ] ||
		die "window on output $((index + 1)) lost its decoration after focus-tag (see $shots)"
done
expect_focus empty none "focusing tag 2 (shown on the empty monitor 2) focuses that monitor"
expect_focus opened 1 "a new window opens on the focused monitor"
expect_focus right1 2 "focus-right from monitor 2 continues onto monitor 3"
expect_focus right2 2 "focus-right past the last monitor stays put"
expect_focus left1 1 "focus-left from monitor 3 returns to monitor 2"
expect_focus left2 0 "focus-left continues onto monitor 1"
# A window on a tag no output shows must leave the screen (its border was white).
[ "$(pixel hidden 6,200)" = "srgb(0,0,0)" ] ||
	die "a window stayed on screen after its tag was switched away (hidden.png; see $shots)"
# A restarted whirlpool restores the arrangement: same windows in the same places
# (compared below the bar, which shows a clock).
changed=$(magick compare -metric AE -fuzz 8% "$shots/before.png[3840x600+0+100]" "$shots/after.png[3840x600+0+100]" null: 2>&1 || true)
changed=${changed%% *}
changed=${changed%%.*}
[ "$changed" -lt 3000 ] ||
	die "the arrangement changed across a whirlpool restart: $changed pixels differ (before.png / after.png; see $shots)"
grep -q "Restored layout" "$shots/whirlpool2.log" || die "restart did not restore layout state (see $shots/whirlpool2.log)"
if grep -qE "error:|panic|cleanup failed" "$shots/whirlpool.log" "$shots/whirlpool2.log"; then
	die "whirlpool logged an error (see $shots/whirlpool.log)"
fi
log "PASS: decorations, monitor focus (with and without windows), edge navigation"
