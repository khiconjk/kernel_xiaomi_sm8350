#!/system/bin/sh
# V108 non-root ghost-uptime audit for Xiaomi 11T Pro (vili).
# The script is read-only, never invokes su, and works from adb shell or a
# normal Android terminal. ADB shell can read more surfaces than an app UID.

set -u
umask 077

VERSION="V108"
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)"

choose_output()
{
	if [ "$#" -gt 0 ] && [ -n "${1:-}" ]; then
		case "$1" in
			*.txt) printf '%s\n' "$1" ;;
			*) printf '%s/%s-noroot-uptime-audit-%s.txt\n' "${1%/}" "$VERSION" "$STAMP" ;;
		esac
		return
	fi

	for dir in /sdcard/Download /data/local/tmp /sdcard /tmp .; do
		if [ -d "$dir" ] && [ -w "$dir" ]; then
			printf '%s/%s-noroot-uptime-audit-%s.txt\n' "${dir%/}" "$VERSION" "$STAMP"
			return
		fi
	done

	printf './%s-noroot-uptime-audit-%s.txt\n' "$VERSION" "$STAMP"
}

OUT="$(choose_output "${1:-}")"
OUT_DIR="${OUT%/*}"
[ "$OUT_DIR" = "$OUT" ] && OUT_DIR=.
mkdir -p "$OUT_DIR" 2>/dev/null || true
if ! : >"$OUT" 2>/dev/null; then
	OUT="./${VERSION}-noroot-uptime-audit-${STAMP}.txt"
	: >"$OUT" || exit 1
fi

say()
{
	printf '%s\n' "$*" >>"$OUT"
}

section()
{
	say ""
	say "===== $* ====="
}

capture()
{
	title="$1"
	shift
	section "$title"
	{
		printf 'COMMAND:'
		for arg in "$@"; do printf ' %s' "$arg"; done
		printf '\n'
		"$@"
	} >>"$OUT" 2>&1 || say "RESULT: unavailable or permission denied (exit=$?)"
}

read_first()
{
	[ -r "$1" ] || return 1
	awk 'NR == 1 { print $1; exit }' "$1" 2>/dev/null
}

integer_part()
{
	printf '%s\n' "$1" | awk -F. 'NR == 1 { print $1 + 0 }'
}

numeric_or_zero()
{
	case "${1:-}" in
		''|*[!0-9]*) printf '0\n' ;;
		*) printf '%s\n' "$1" ;;
	esac
}

decimal_add()
{
	awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { printf "%.0f\n", a + b }'
}

less_than_half_uptime_us()
{
	awk -v idle_us="${1:-0}" -v uptime_sec="${2:-0}" \
		'BEGIN { exit !(uptime_sec > 0 && idle_us < uptime_sec * 500000) }'
}

WARN_COUNT=0
PASS_COUNT=0
INFO_COUNT=0

warn()
{
	WARN_COUNT=$((WARN_COUNT + 1))
	say "WARN[$WARN_COUNT]: $*"
}

pass()
{
	PASS_COUNT=$((PASS_COUNT + 1))
	say "PASS[$PASS_COUNT]: $*"
}

info()
{
	INFO_COUNT=$((INFO_COUNT + 1))
	say "INFO[$INFO_COUNT]: $*"
}

say "${VERSION} NON-ROOT GHOST-UPTIME AUDIT"
say "started_utc=$(date -u 2>/dev/null || true)"
say "report=$OUT"
say "mode=read-only; no su; no root required"
say "scope=ADB shell sees more than an ordinary third-party app UID"

section "IDENTITY AND BUILD"
id >>"$OUT" 2>&1 || true
uname -a >>"$OUT" 2>&1 || true
for prop in \
	ro.product.device ro.build.display.id ro.build.fingerprint \
	ro.build.version.release ro.build.version.sdk ro.build.date.utc \
	ro.boot.slot_suffix sys.boot_completed ro.runtime.firstboot; do
	value="$(getprop "$prop" 2>/dev/null || true)"
	say "$prop=$value"
done
if command -v getenforce >/dev/null 2>&1; then
	say "selinux=$(getenforce 2>/dev/null || true)"
fi

PROC_UP_RAW="$(read_first /proc/uptime || true)"
PROC_UP_SEC="$(integer_part "${PROC_UP_RAW:-0}")"
PROC_UP_SEC="$(numeric_or_zero "$PROC_UP_SEC")"

section "PRIMARY UPTIME CROSS-CHECK"
say "proc_uptime_raw=${PROC_UP_RAW:-unavailable}"
if [ "$PROC_UP_SEC" -gt 0 ]; then
	pass "/proc/uptime readable; integer seconds=$PROC_UP_SEC"
else
	warn "/proc/uptime is unavailable or not numeric"
fi

if command -v uptime >/dev/null 2>&1; then
	say "uptime_command=$(uptime 2>&1 || true)"
fi
if command -v toybox >/dev/null 2>&1; then
	say "toybox_uptime=$(toybox uptime 2>&1 || true)"
fi
if command -v busybox >/dev/null 2>&1; then
	say "busybox_uptime=$(busybox uptime 2>&1 || true)"
fi

BTIME="$(awk '$1 == "btime" { print $2; exit }' /proc/stat 2>/dev/null || true)"
NOW_EPOCH="$(date +%s 2>/dev/null || true)"
BTIME="$(numeric_or_zero "$BTIME")"
NOW_EPOCH="$(numeric_or_zero "$NOW_EPOCH")"
say "proc_stat_btime=$BTIME"
say "wall_epoch_now=$NOW_EPOCH"
if [ "$BTIME" -gt 0 ] && [ "$NOW_EPOCH" -gt "$BTIME" ] && [ "$PROC_UP_SEC" -gt 0 ]; then
	WALL_AGE=$((NOW_EPOCH - BTIME))
	DIFF=$((WALL_AGE - PROC_UP_SEC))
	[ "$DIFF" -lt 0 ] && DIFF=$((-DIFF))
	say "wall_clock_minus_btime_sec=$WALL_AGE"
	say "abs_diff_vs_proc_uptime_sec=$DIFF"
	if [ "$DIFF" -le 10 ]; then
		pass "/proc/stat btime agrees with /proc/uptime within 10 seconds"
	else
		warn "/proc/stat btime differs from /proc/uptime by ${DIFF}s"
	fi
else
	info "btime comparison skipped because wall clock or fields were unavailable"
fi

HZ="$(getconf CLK_TCK 2>/dev/null || true)"
HZ="$(numeric_or_zero "$HZ")"
[ "$HZ" -gt 0 ] || HZ=100
say "userspace_CLK_TCK=$HZ"
for pid in self 1; do
	stat_file="/proc/$pid/stat"
	start_ticks="$(sed 's/^.*) //' "$stat_file" 2>/dev/null | awk 'NR == 1 { print $20; exit }')"
	start_ticks="$(numeric_or_zero "$start_ticks")"
	start_sec=$((start_ticks / HZ))
	say "pid_${pid}_start_ticks=$start_ticks"
	say "pid_${pid}_start_seconds_on_exposed_monotonic_axis=$start_sec"
	if [ "$PROC_UP_SEC" -gt 0 ] && [ "$start_sec" -gt $((PROC_UP_SEC + 10)) ]; then
		warn "/proc/$pid/stat starttime is more than 10 seconds later than exposed uptime"
	fi
done

section "CPUIDLE SYSFS TIME (V108 TARGET)"
CPU_FOUND=0
CPU_CHECKED=0
CPU_WARN=0
for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
	[ -d "$cpu_dir" ] || continue
	CPU_FOUND=$((CPU_FOUND + 1))
	cpu_name="${cpu_dir##*/}"
	online=1
	if [ -r "$cpu_dir/online" ]; then
		online="$(read_first "$cpu_dir/online" || echo 0)"
		online="$(numeric_or_zero "$online")"
	fi
	say "-- $cpu_name online=$online --"
	sum_us=0
	states=0
	for state_dir in "$cpu_dir"/cpuidle/state[0-9]*; do
		[ -d "$state_dir" ] || continue
		states=$((states + 1))
		state_name="$(read_first "$state_dir/name" || true)"
		state_time="$(read_first "$state_dir/time" || true)"
		state_usage="$(read_first "$state_dir/usage" || true)"
		state_disable="$(read_first "$state_dir/disable" || true)"
		state_time="$(numeric_or_zero "$state_time")"
		# Android's /system/bin/sh may use signed 32-bit arithmetic. cpuidle
		# microseconds exceed INT_MAX quickly, so sum through awk instead.
		sum_us="$(decimal_add "$sum_us" "$state_time")"
		say "${state_dir##*/}: name=${state_name:-?} time_us=$state_time usage=${state_usage:-?} disable=${state_disable:-?}"
	done
	say "$cpu_name.cpuidle_state_count=$states"
	say "$cpu_name.cpuidle_sum_us=$sum_us"
	if [ "$online" -eq 1 ] && [ "$states" -gt 0 ] && [ "$PROC_UP_SEC" -gt 0 ]; then
		CPU_CHECKED=$((CPU_CHECKED + 1))
		percent="$(awk -v a="$sum_us" -v b="$PROC_UP_SEC" 'BEGIN { if (b > 0) printf "%.2f", (100 * a / (b * 1000000)); else print "0.00" }')"
		say "$cpu_name.cpuidle_sum_percent_of_proc_uptime=$percent"
		# Idle sum can legitimately be lower than uptime under load, but a very
		# small value compared with a multi-day fake uptime is a strong leak.
		if less_than_half_uptime_us "$sum_us" "$PROC_UP_SEC"; then
			CPU_WARN=$((CPU_WARN + 1))
			warn "$cpu_name cpuidle time is below 50% of exposed uptime; likely real-boot-age leak"
		else
			pass "$cpu_name cpuidle time is no longer obviously shorter than exposed uptime"
		fi
	fi
done
say "cpuidle_cpu_dirs=$CPU_FOUND checked_online=$CPU_CHECKED warned=$CPU_WARN"
if [ "$CPU_FOUND" -eq 0 ]; then
	info "cpuidle sysfs is absent on this runtime"
fi

section "CPUFREQ TIME_IN_STATE (NEXT CANDIDATE, NOT PATCHED BY V108)"
TIS_FOUND=0
for tis in /sys/devices/system/cpu/cpufreq/policy[0-9]*/stats/time_in_state \
	/sys/devices/system/cpu/cpu[0-9]*/cpufreq/stats/time_in_state; do
	[ -r "$tis" ] || continue
	TIS_FOUND=$((TIS_FOUND + 1))
	say "-- $tis --"
	tis_ticks="$(awk '$2 ~ /^[0-9]+$/ { total += $2 } END { printf "%.0f\n", total + 0 }' "$tis" 2>/dev/null || echo 0)"
	tis_ticks="$(numeric_or_zero "$tis_ticks")"
	cat "$tis" >>"$OUT" 2>&1 || true
	tis_seconds="$(awk -v ticks="$tis_ticks" -v hz="$HZ" 'BEGIN { if (hz > 0) printf "%.2f", ticks / hz; else print "0.00" }')"
	tis_percent="$(awk -v ticks="$tis_ticks" -v hz="$HZ" -v up="$PROC_UP_SEC" 'BEGIN { if (hz > 0 && up > 0) printf "%.2f", 100 * ticks / (hz * up); else print "0.00" }')"
	say "sum_raw_ticks=$tis_ticks"
	say "sum_seconds_at_CLK_TCK=$tis_seconds"
	say "sum_percent_of_proc_uptime=$tis_percent"
done
if [ "$TIS_FOUND" -eq 0 ]; then
	info "no readable cpufreq time_in_state file"
else
	info "cpufreq time_in_state found; its tick sum is reported as seconds and percent of exposed /proc/uptime"
fi

section "OTHER READABLE TIME SURFACES"
for path in \
	/proc/pressure/cpu /proc/pressure/io /proc/pressure/memory \
	/sys/power/suspend_stats \
	/sys/kernel/debug/suspend_stats \
	/sys/kernel/debug/wakeup_sources \
	/sys/kernel/wakeup_reasons/last_suspend_time \
	/sys/kernel/wakeup_reasons/last_resume_reason \
	/proc/timer_list /proc/softirqs /proc/interrupts; do
	say "-- $path --"
	if [ -r "$path" ]; then
		say "readable=yes"
		head -n 80 "$path" >>"$OUT" 2>&1 || true
	else
		say "readable=no"
	fi
done

section "BOOT AND SERVICE PROPERTIES"
if command -v getprop >/dev/null 2>&1; then
	getprop 2>/dev/null | grep -E '\[(ro\.boottime\.|ro\.runtime\.firstboot|sys\.boot_completed|init\.svc\.)' | head -n 250 >>"$OUT" 2>&1 || true
else
	info "getprop unavailable"
fi
if command -v settings >/dev/null 2>&1; then
	say "global.boot_count=$(settings get global boot_count 2>/dev/null || true)"
fi

section "DUMPSYS TIME SNIPPETS"
if command -v dumpsys >/dev/null 2>&1; then
	for service in alarm power batterystats activity; do
		say "-- dumpsys $service --"
		dumpsys "$service" 2>/dev/null | \
			grep -iE 'uptime|elapsed|realtime|start clock|time since|last wake|last sleep|boot' | \
			head -n 160 >>"$OUT" 2>&1 || say "unavailable or no matching lines"
	done
	info "dumpsys snippets need manual review; service output may use a different clock domain"
else
	info "dumpsys unavailable for this UID"
fi

section "KERNEL LOG ACCESS"
if dmesg >/dev/null 2>&1; then
	say "dmesg_readable=yes"
	dmesg 2>/dev/null | head -n 20 >>"$OUT" || true
else
	say "dmesg_readable=no"
fi
if [ -r /dev/kmsg ]; then
	say "/dev/kmsg_readable=yes (not consumed by this audit)"
else
	say "/dev/kmsg_readable=no"
fi

section "SUMMARY"
say "passes=$PASS_COUNT"
say "warnings=$WARN_COUNT"
say "information=$INFO_COUNT"
say "high_confidence_v108_target=cpuidle state time"
say "v106_log_finding=cpuidle and cpufreq totals track roughly 39 minutes of real runtime while proc uptime exposes roughly 19 days"
say "v106_consistency_finding=uptime command reported roughly twice proc uptime; review V106 sysinfo for a possible second offset in a later isolated version"
say "next_candidates_to_review=V106 sysinfo double-offset consistency first, then cpufreq time_in_state"
say "important=The V106 baseline report has been supplied. Run this on V108 after boot and send the new report for a delta comparison."
say "important=This shell audit cannot directly invoke Java SystemClock APIs; dumpsys is used only as an indirect cross-check."

printf 'DONE: %s\n' "$OUT"
printf 'Summary: PASS=%s WARN=%s INFO=%s\n' "$PASS_COUNT" "$WARN_COUNT" "$INFO_COUNT"

exit 0
