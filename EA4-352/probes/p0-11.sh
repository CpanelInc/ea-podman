#!/bin/bash
# P0-11: the bounded as-user runner (PLAN.md 4.2a).
#  - how `systemd-run --wait` reports Result=timeout vs a non-zero exit, per systemd version;
#  - on a timeout, are a SIGSTOPped child, a ptrace-stopped child and a setsid/double-forked
#    grandchild all reaped?
#  - can the account move a runner process into its own delegated cgroup (v1 and v2), and does
#    --wait still return?
#  - podman against old and new storage from the runner; podman build/run from a plain runner
#    vs a delegated one (split needs a delegated cgroup to start a container).
set -uo pipefail
cd "$(dirname "$0")"; . ./plib.sh
TAG=$$
runner() {    # timeout, then argv; prints systemd-run's own stderr too (no --quiet)
    local tmo=$1; shift
    seq=$((seq + 1))
    systemd-run --uid="$UID_" --gid="$GID_" --slice="eapodman-$UID_.slice" \
        --unit="eapodman-run-$UID_-p011-$$-$seq" --pipe --wait --collect \
        -p RuntimeMaxSec="$tmo" -p TimeoutStopSec=10 -p KillMode=control-group \
        -p WorkingDirectory="$HOME_" "${ENVS[@]}" "$@" </dev/null
}
leftovers() { pgrep -u "$U" -f "sleep 3$TAG" | tr '\n' ' '; }
cleanup() { pkill -9 -u "$U" -f "sleep 3$TAG" 2>/dev/null; pkill -9 -u "$U" -f "p011-escape-$$" 2>/dev/null; }
trap 'cleanup; rm -f /tmp/p011-*-$$.sh' EXIT

hdr "exit reporting"
for cmd in "true" "sh -c 'exit 7'" "sleep 30"; do
    t0=$(date +%s)
    out=$(eval runner 3 $cmd 2>&1); rc=$?
    t=$(( $(date +%s) - t0 ))
    info "[$cmd] rc=$rc after ${t}s: $(grep -v '^Running as unit' <<<"$out" | tr '\n' ' ')"
    key=$(case $cmd in true) echo ok;; sh*) echo exit7;; *) echo timeout;; esac)
    result "report_$key" "rc=$rc; $(grep -oE 'Finished with result: [a-z-]+|Main processes terminated with: [^ ]+ ?[^ ]*' <<<"$out" | tr '\n' ';')"
done

hdr "reaping on timeout"
# One unit holds: a SIGSTOPped child, a ptrace-stopped child (python3 PTRACE_ATTACH, never
# continued), a setsid -f grandchild, and a double-forked grandchild.
script=$(cat <<EOF
sleep 3${TAG}1 & sleep 0.5; kill -STOP \$!
python3 -c 'import ctypes,subprocess,time
p=subprocess.Popen(["sleep","3${TAG}2"]); ctypes.CDLL(None).ptrace(16,p.pid,0,0); time.sleep(999)' &
setsid -f sleep 3${TAG}3
( sleep 3${TAG}4 & ) &
sleep 2
for p in \$(pgrep -u \$(id -u) -f "sleep 3${TAG}"); do echo "\$p \$(awk '{print \$3}' /proc/\$p/stat) \$(cat /proc/\$p/comm) sid=\$(ps -o sid= -p \$p)"; done
wait
EOF
)
t0=$(date +%s)
acct_pids() { pgrep -u "$U" | sort; }
before_pids=$(acct_pids)
# A file, not sh -c: systemd-run expands $ in its command line.
sf=/tmp/p011-reap-$$.sh; printf '%s\n' "$script" >"$sf"; chmod 0755 "$sf"
out=$(runner 6 /bin/sh "$sf" 2>&1); rc=$?; rm -f "$sf"
t=$(( $(date +%s) - t0 ))
info "$out"
info "runner returned rc=$rc after ${t}s"
grep -q " T " <<<"$out" && result sigstop_child_present_before yes || result sigstop_child_present_before NO
grep -q " t " <<<"$out" && result ptrace_stopped_child_present_before yes || result ptrace_stopped_child_present_before NO
sleep 1
left=$(comm -13 <(echo "$before_pids") <(acct_pids) | tr '\n' ' ')
result all_reaped_on_timeout "$([ -z "$left" ] && echo yes || echo "NO: $(ps -o pid,stat,args -p ${left// /,} | tail -n +2 | tr '\n' ';')")"
result timeout_returned_after_s "$t"

hdr "escape into the account's own delegated cgroup"
web=ea-podman-web.$U.01.service
if [ $CGV = 2 ]; then
    base=$CG/eapodman.slice/eapodman-$UID_.slice/$web
    leaf=$(find "$base" -mindepth 1 -maxdepth 1 -type d ! -name 'libpod-payload-*' | head -1)
    targets=("${leaf:-$base}/cgroup.procs")
else
    targets=()
    for h in $CG/systemd $CG/pids $CG/memory $CG/cpu,cpuacct; do
        [ -d "$h/eapodman.slice/eapodman-$UID_.slice/$web" ] && targets+=("$h/eapodman.slice/eapodman-$UID_.slice/$web/cgroup.procs")
    done
fi
info "targets: ${targets[*]}"
ls -l "${targets[@]}" 2>&1 | sed 's/^/  /'
# The child moves itself (not the unit's main process, which systemd kills by PID anyway).
esc=$(cat <<EOF
sh -c 'for t in ${targets[*]}; do echo \$\$ >"\$t" 2>/dev/null && echo "moved \$t" || echo "denied \$t"; done
sed "s/^/cg: /" /proc/\$\$/cgroup; exec sleep 3${TAG}5' &
wait
EOF
)
t0=$(date +%s)
sf=/tmp/p011-esc-$$.sh; printf '%s\n' "$esc" >"$sf"; chmod 0755 "$sf"
# A pipe (SELinux stops PID 1 writing to a file passed with --pipe), read with a deadline: an
# escaped child keeps the pipe open (v1), so a reader that waits for EOF would hang.
rcf=/tmp/p011-esc-$$.rc
out=$( { runner 5 /bin/sh "$sf" 2>&1; echo $? >"$rcf"; } | timeout 30 cat ); rc=$(cat "$rcf"); rm -f "$sf" "$rcf"
t=$(( $(date +%s) - t0 ))
info "$out"
moved=$(grep -c '^moved' <<<"$out"); denied=$(grep -c '^denied' <<<"$out")
result escape_writes "moved=$moved denied=$denied ($(grep -o '^moved .*' <<<"$out" | sed "s|.*$CG/||; s|/eapodman.slice.*||" | tr '\n' ' '))"
result escape_wait_returned_after_s "$t (rc=$rc)"
sleep 1
sur=$(pgrep -u "$U" -f "sleep 3${TAG}5")
result escaped_process_survives "$([ -n "$sur" ] && echo "YES (pid $sur: $(grep -E 'name=systemd|pids|^0::' /proc/$sur/cgroup 2>/dev/null | tr '\n' ' '))" || echo no)"
if [ -n "$sur" ]; then
    systemctl restart "$web"; sleep 2
    result escaped_process_killed_by_web_restart "$(kill -0 $sur 2>/dev/null && echo no || echo yes)"
fi
cleanup

hdr "podman from the runner: new storage and old storage"
o=$(runner 120 /usr/bin/podman ps -a --format '{{.Names}}' 2>&1 | grep -v '^Running as unit\|^Finished\|^Main proc\|^Service runtime\|^CPU time\|^IP traffic\|^IO bytes\|^Memory peak\|^Memory swap'); rc=$?
info "new storage: $(tr '\n' ' ' <<<"$o")"
result podman_new_storage "$(grep -q "web.$U.01" <<<"$o" && echo works || echo "FAILS: $o")"
write_old_storage_conf
o=$(as_user_env 120 "${PINNED_OLD[@]}" -- /usr/bin/podman info --format '{{.Store.GraphRoot}} {{.Store.RunRoot}}' 2>&1)
result podman_old_storage "$(tail -1 <<<"$o")"

hdr "podman run/build from a plain runner vs a delegated one"
ctx=$HOME_/.p011-build; install -d -o "$U" -g "$GID_" "$ctx"
printf 'FROM %s\nRUN echo p011-build-ran\n' "$IMAGE" >"$ctx/Containerfile"; chown "$U:$GID_" "$ctx/Containerfile"
o=$(as_user /usr/bin/podman build --no-cache -t localhost/p011:latest "$ctx" 2>&1); rc=$?
result build_with_run_plain_runner "$([ $rc = 0 ] && echo works || echo "FAILS: $(grep -m1 -i 'error' <<<"$o")")"
o=$(as_user_deleg /usr/bin/podman build --no-cache -t localhost/p011:latest "$ctx" 2>&1); rc=$?
result build_with_run_delegated_runner "$([ $rc = 0 ] && echo works || echo "FAILS: $(grep -m1 -i 'error' <<<"$o")")"
o=$(as_user /usr/bin/podman run --rm "$IMAGE" true 2>&1); rc=$?
result run_rm_plain_runner "$([ $rc = 0 ] && echo works || echo "FAILS: $(tail -1 <<<"$o")")"
o=$(as_user_deleg /usr/bin/podman run --rm "$IMAGE" true 2>&1); rc=$?
result run_rm_delegated_runner "$([ $rc = 0 ] && echo works || echo "FAILS: $(tail -1 <<<"$o")")"
as_user /usr/bin/podman rmi -f localhost/p011:latest >/dev/null 2>&1
rm -rf "$ctx"
