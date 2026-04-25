#!/bin/sh
# forensics.sh - capture and analyze a shutdown SIGSEGV from an LTO-built grpc.so.
#
# Runs grpc_call.php under gdb in batch mode in a loop. When gdb catches a
# SIGSEGV, prints the canonical set of post-mortem queries:
#
#   - info threads               (which threads existed at the crash)
#   - thread apply all bt        (every thread's call stack)
#   - info sharedlibrary         (whether grpc.so is still in the loaded list)
#   - info proc mappings         (whether $pc lies inside any mapping)
#   - info registers             (the actual $pc value)
#   - x/10i $pc                  (whether instruction fetch from $pc works)
#
# Together those show the dlclose-vs-worker-thread race directly: main thread
# inside __cxa_finalize / dl_fini, crashing thread with $pc in a no-longer
# mapped address range, grpc.so absent from the loaded library list.
#
# Use inside the php85-lto-forensics container target, which is built with
# -flto=auto and ships gdb (other -lto* targets do not have gdb installed).
#
# Env:
#   N=NNN              maximum number of attempts (default 2000)
#   GRPC_TARGET=host:port   gRPC endpoint for grpc_call.php (default spanner-emulator:9010)

set -eu

target_php="${TARGET_PHP:-/usr/local/bin/php}"
script="${REPRO_SCRIPT:-/repro/grpc_call.php}"
maxruns="${N:-2000}"

if ! command -v gdb >/dev/null 2>&1; then
    echo "forensics.sh: gdb is not installed in this image" >&2
    echo "use the php85-lto-forensics target (compose service of the same name)" >&2
    exit 2
fi

i=0
while [ "$i" -lt "$maxruns" ]; do
    out="$(
        gdb -batch -nx -q \
            -ex "set pagination off" \
            -ex "set confirm off" \
            -ex "handle SIGPIPE nostop noprint pass" \
            -ex "handle SIGTERM nostop noprint pass" \
            -ex "run" \
            -ex "printf \"\\n=== info threads ===\\n\"" \
            -ex "info threads" \
            -ex "printf \"\\n=== thread apply all bt ===\\n\"" \
            -ex "thread apply all bt" \
            -ex "printf \"\\n=== info sharedlibrary ===\\n\"" \
            -ex "info sharedlibrary" \
            -ex "printf \"\\n=== info proc mappings ===\\n\"" \
            -ex "info proc mappings" \
            -ex "printf \"\\n=== info registers ===\\n\"" \
            -ex "info registers" \
            -ex "printf \"\\n=== x/10i \\$pc ===\\n\"" \
            -ex "x/10i \$pc" \
            --args "$target_php" -n \
                -d display_errors=0 -d log_errors=On \
                -d extension=grpc \
                -d grpc.grpc_verbosity=ERROR \
                -d grpc.enable_fork_support=0 \
                "$script" 2>&1
    )"

    if printf '%s' "$out" | grep -q "Program received signal SIGSEGV"; then
        echo "=== SIGSEGV captured on iteration $i ==="
        printf '%s\n' "$out"
        exit 0
    fi

    i=$((i + 1))
done

echo "forensics.sh: no SIGSEGV captured in $maxruns runs" >&2
exit 2
