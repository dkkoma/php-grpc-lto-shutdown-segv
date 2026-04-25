#!/bin/sh
# Loops grpc_call.php N times in a single container and counts SIGSEGV vs
# clean exits. POSIX sh so it runs on Alpine (busybox ash) too.
#
# Env:
#   N                 iterations (default 100)
#   GRPC_EXPERIMENTS  passed through to php (default: "")
#   GRPC_DNS_RESOLVER passed through to php (default: "")

set -u
N=${N:-100}
ulimit -c 0

here=$(cd "$(dirname "$0")" && pwd)

segv=0
ok=0
i=0
while [ "$i" -lt "$N" ]; do
    i=$((i+1))
    php -n \
      -d display_errors=0 \
      -d log_errors=On \
      -d extension=grpc \
      -d grpc.grpc_verbosity=ERROR \
      -d grpc.enable_fork_support=0 \
      "${here}/grpc_call.php" > /dev/null 2>&1
    if [ "$?" -eq 0 ]; then
        ok=$((ok+1))
    else
        segv=$((segv+1))
    fi
done

echo "N=$N segv=$segv ok=$ok GRPC_EXPERIMENTS='${GRPC_EXPERIMENTS:-}' GRPC_DNS_RESOLVER='${GRPC_DNS_RESOLVER:-}'"
