#!/bin/sh
# forensics.sh - capture and analyze a shutdown SIGSEGV from an LTO-built grpc.so.
#
# Runs grpc_call.php in a tight loop with core dumps enabled. When the
# kernel writes out a core file, runs gdb post-mortem on it and prints:
#
#   - info threads               (which threads existed at the crash)
#   - thread apply all bt        (every thread's call stack)
#   - info sharedlibrary         (whether grpc.so is still in the loaded list)
#   - info proc mappings         (whether $pc lies inside any mapping)
#   - info registers             (the actual $pc value)
#   - x/10i $pc                  (whether instruction fetch from $pc works)
#
# Together those show the dlclose-vs-worker-thread race directly.
#
# We capture cores out-of-process rather than running php under gdb because
# gdb-as-parent serialises signal / event delivery enough to suppress the
# race entirely (heisenbug — gdb-attached runs do not reproduce).
#
# Use inside the php85-lto-forensics container target, which is built with
# -flto=auto and ships gdb (other -lto* targets do not have gdb installed).
#
# Env:
#   N=NNN   maximum number of attempts (default 2000)

set -eu

target_php="${TARGET_PHP:-/usr/local/bin/php}"
script="${REPRO_SCRIPT:-/repro/grpc_call.php}"
maxruns="${N:-2000}"

if ! command -v gdb >/dev/null 2>&1; then
    echo "forensics.sh: gdb is not installed in this image" >&2
    echo "use the php85-lto-forensics target (compose service of the same name)" >&2
    exit 2
fi

# Kernel needs core_pattern=core (relative) for this to deposit cores
# in our cwd. The official php:8.5.5-cli image's host kernel uses that
# default; if your host overrides it (systemd-coredump etc.), edit
# core_pattern or run --privileged.
core_pattern="$(cat /proc/sys/kernel/core_pattern 2>/dev/null || echo)"
case "$core_pattern" in
    core|core.*) ;;
    *)
        echo "forensics.sh: warning: kernel.core_pattern='$core_pattern'" >&2
        echo "  expected 'core' or 'core.*'; cores may not land in cwd" >&2
        ;;
esac

ulimit -c unlimited

workdir="$(mktemp -d)"
cd "$workdir"

# Canonical post-mortem query script.
gdb_script="$workdir/gdb-cmds"
cat > "$gdb_script" <<'GDB'
set pagination off
set confirm off
printf "\n=== info threads ===\n"
info threads
printf "\n=== thread apply all bt ===\n"
thread apply all bt
printf "\n=== info sharedlibrary ===\n"
info sharedlibrary
printf "\n=== info proc mappings ===\n"
info proc mappings
printf "\n=== info registers ===\n"
info registers
printf "\n=== x/10i $pc ===\n"
x/10i $pc
GDB

i=0
while [ "$i" -lt "$maxruns" ]; do
    rm -f core core.*
    "$target_php" -n \
        -d display_errors=0 -d log_errors=On \
        -d extension=grpc \
        -d grpc.grpc_verbosity=ERROR \
        -d grpc.enable_fork_support=0 \
        "$script" >/dev/null 2>&1 || true

    core="$(ls -t core core.* 2>/dev/null | head -n1 || true)"
    if [ -n "$core" ] && [ -f "$core" ]; then
        echo "=== SIGSEGV core captured on iteration $i: $workdir/$core ==="
        gdb -batch -nx -q -x "$gdb_script" "$target_php" "$core" 2>&1 || true
        rm -f core core.*
        exit 0
    fi

    i=$((i + 1))
done

echo "forensics.sh: no SIGSEGV core captured in $maxruns runs" >&2
exit 2
