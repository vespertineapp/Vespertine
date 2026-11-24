#!/bin/bash
# Runs a test command; if it is still running after the limit (seconds), prints the stacks of the test processes, stops
# them and fails, so a hung test shows where it is stuck instead of only running into the job's timeout.
#   scripts/run-with-watchdog.sh 600 swift test --package-path Packages/VespertineKit -c release
# A run can also stall for minutes and then go on (the threads the tests share all held by one of them), which the limit
# never sees. So when the command prints nothing for WATCHDOG_QUIET seconds (120 unless set, 0 turns it off), the stacks
# are printed then too, once for each quiet spell, and the run goes on.
# Only the command's own process tree is sampled and stopped, by process ID: other test runs on the same machine (a second
# checkout, another job on a shared runner) are left alone.
set -u
limit=$1; shift
quiet=${WATCHDOG_QUIET:-120}
output=$(mktemp -t watchdog-output)
trap 'rm -f "$output"' EXIT
"$@" > >(tee "$output") 2>&1 &
pid=$!

# The process IDs below $1, children first.
descendants() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        descendants "$child"
        echo "$child"
    done
}

# Prints the stacks of the test processes under the command.
stacks() {
    local p command
    for p in $(descendants "$pid"); do
        command=$(ps -o command= -p "$p" 2>/dev/null)
        case "$command" in
            *swiftpm-testing-helper*|*xctest*)
                echo "=== $p: $command"
                sample "$p" 3 -file "/tmp/sample-$p.txt" >/dev/null 2>&1 && cat "/tmp/sample-$p.txt" ;;
        esac
    done
}

size=0; silent=0; sampled=false
for ((i = 0; i < limit; i++)); do
    if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; exit $?; fi
    sleep 1
    now=$(stat -f %z "$output" 2>/dev/null || echo 0)
    if [ "$now" != "$size" ]; then size=$now; silent=0; sampled=false; continue; fi
    silent=$((silent + 1))
    if [ "$quiet" -gt 0 ] && [ "$silent" -ge "$quiet" ] && ! $sampled; then
        sampled=true
        echo "::warning::Nothing printed for ${quiet} s (${i} s into the run). Stacks of the test processes follow; the run goes on."
        stacks
    fi
done
echo "::error::Still running after ${limit} s. Stacks of the test processes follow."
stacks
tree=$(descendants "$pid")
for p in $tree "$pid"; do kill "$p" 2>/dev/null; done
sleep 2
for p in $tree "$pid"; do kill -9 "$p" 2>/dev/null; done
exit 1
