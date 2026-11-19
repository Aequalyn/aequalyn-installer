#!/usr/bin/env bash
# mock of lib/apply.sh for the UI self-test: streams plausible progress lines
# into the installer's log view, writes the log file like the real one does,
# exits 1 on the first invocation (the failed install) and 0 on the second
# (the Retry that succeeds). Never touches a disk.
set -u
config="${1:-}"
logfile="${3:-/dev/null}"
count="${AEQUALYN_E2E_SANDBOX:-/tmp}/apply-count"
n=0
[ -f "$count" ] && n="$(cat "$count")"
echo $((n + 1)) > "$count"

say() { echo "$1"; echo "$(date '+%H:%M:%S') $1" >> "$logfile"; }

say "[mock] apply.sh started, config: $config"
sleep 1
say "[mock] wiping and partitioning /dev/mock-disk (fullwipe, no encryption)"
sleep 1.5
say "[mock] pacstrap: base, linux, aequalyn-minimal"
sleep 1.5
say "[mock] configuring user, timezone UTC, profile minimal"
sleep 1
if [ "$n" -eq 0 ]; then
    echo "[mock] ERROR: simulated failure on the first attempt" >&2
    echo "$(date '+%H:%M:%S') [mock] ERROR: simulated failure" >> "$logfile"
    exit 1
fi
say "[mock] boot loader installed -- done"
exit 0
