# PHP ext-grpc shutdown SIGSEGV: investigation log

Detailed bisection notes that lead to `-flto=auto` as the trigger and
`RTLD_NODELETE` as a workaround. The README has the summary; this file
has the data behind it.

## Repro harness

- `grpc_call.php`: raw `Grpc\Channel` + `Grpc\Call::startBatch` against
  `spanner-emulator:9010`, calling
  `/google.spanner.admin.instance.v1.InstanceAdmin/ListInstanceConfigs`
  with a hand-encoded protobuf body. Server replies 200 OK with a real
  84-byte response. No composer, no SDK, no PHP framework.
- `loop.sh`: POSIX shell, runs the php script `N` times under
  `php -n -d extension=grpc -d grpc.grpc_verbosity=ERROR
   -d grpc.enable_fork_support=0 ...` and counts non-zero exits as
  SIGSEGV.
- `compose.yaml`: each service builds grpc with a different flag/patch
  combo and shares the same loop.sh + emulator.

All numbers below are from OrbStack on Apple Silicon, native arm64.
amd64 emulation is noted to behave differently (see "Architecture
sensitivity" at the bottom).

## Result matrix

| service                          | grpc.so build                                                                                      | PHP    | grpc   |    N | SEGV |  rate |
|----------------------------------|----------------------------------------------------------------------------------------------------|-------:|-------:|-----:|-----:|------:|
| `php85-debian`                   | stock `pecl install grpc`                                                                          |  8.5.5 |   1.80 |  500 |    0 |    0% |
| `php85-nolto`                    | `EXTRA_CFLAGS="-O3 -fno-semantic-interposition -march=native"` (no LTO)                            |  8.5.5 |   1.80 |  500 |    0 |    0% |
| `php85-lto`                      | `EXTRA_CFLAGS="-O3 -flto=auto -fno-semantic-interposition -march=native" + EXTRA_LDFLAGS=-flto=auto`    |  8.5.5 |   1.80 |  500 |  202 | 40.4% |
| `php85-ltoonly`                  | `EXTRA_CFLAGS="-flto=auto" + EXTRA_LDFLAGS=-flto=auto`                                             |  8.5.5 |   1.80 |  500 |  169 | 33.8% |
| `php85-lto-shutdownblocking`     | LTO + replace `grpc_shutdown()` with `grpc_shutdown_blocking()` in `PHP_MSHUTDOWN_FUNCTION(grpc)`  |  8.5.5 |   1.80 |  500 |  160 | 32.0% |
| `php85-lto-waitforasync`         | LTO + add `grpc_maybe_wait_for_async_shutdown()` after `grpc_shutdown()` (C++ bridge)              |  8.5.5 |   1.80 |  500 |  166 | 33.2% |
| `php85-lto-shutdownee`           | LTO + call `grpc_event_engine::experimental::ShutdownDefaultEventEngine()` from MSHUTDOWN          |  8.5.5 |   1.80 |  500 |   18 |  3.6% |
| `php85-lto-shutdownee-stalled`   | shutdownee + `SetWaitForSingleOwnerStalledCallback` instrumentation                                |  8.5.5 |   1.80 |  200 |    8 |  4.0% |
| **`php85-lto-nodelete`**         | **LTO + `dlopen(self, RTLD_NOLOAD\|RTLD_NODELETE)` in MINIT**                                      |  8.5.5 |   1.80 | 2000 |    0 |    0% |

## GRPC_EXPERIMENTS / GRPC_DNS_RESOLVER on the LTO build (N=100)

| label             | GRPC_EXPERIMENTS                                                                                                                                                                       | GRPC_DNS_RESOLVER | SEGV |
|-------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------|-----:|
| baseline          | (empty)                                                                                                                                                                                | (empty)           |   23 |
| ee_off            | `-event_engine_client,-event_engine_listener,-event_engine_dns,-event_engine_dns_non_client_channel,-event_engine_callback_cq,-event_engine_for_all_other_endpoints,-event_engine_fork`| (empty)           |   32 |
| dns_native        | (empty)                                                                                                                                                                                | `native`          |   29 |
| ee_off + native   | (all ee off)                                                                                                                                                                           | `native`          |   30 |

→ All within noise band. `GRPC_EXPERIMENTS` and `GRPC_DNS_RESOLVER` do
not alter the outcome.

## `grpc.enable_fork_support` (N=100)

| `grpc.enable_fork_support` | SEGV |
|----------------------------|-----:|
| `0`                        |   23 |
| `1`                        |   36 |

→ No mitigation; if anything, fork_support=1 trends slightly worse on
this raw repro. Anecdotal "fork_support=1 makes the crash go away"
reports from heavier app stacks were almost certainly sample-size
artifacts.

## Findings, in the order they were established

1. **Stock `pecl install grpc-1.80.0` on `php:8.5.5-cli` is clean** —
   0/500 SEGV.
2. **`GRPC_EXPERIMENTS` (event_engine_*), `GRPC_DNS_RESOLVER`, and
   `grpc.enable_fork_support` do not affect the rate** — they all
   land in the same noise band on the bad build.
3. **Bisecting the optimization-flag set narrows the trigger to
   `-flto=auto` alone.** The full
   `-O3 -flto=auto -fno-semantic-interposition -march=native` set
   reproduces at 40%; `-O3 -fno-semantic-interposition -march=native`
   without LTO is 0; `-flto=auto` by itself is 34%. `-O3` /
   `-fno-semantic-interposition` / `-march=native` are innocent.
4. **Mitigations targeted at gRPC's MSHUTDOWN don't fix it.**
   `grpc_shutdown_blocking()` and `grpc_maybe_wait_for_async_shutdown()`
   each leave the crash rate essentially unchanged. So the race is
   not "shutdown returned too early before async work finished" —
   they all return cleanly, and we still crash.
5. **Calling `ShutdownDefaultEventEngine()` from MSHUTDOWN cuts the
   rate by ~10x** (33.8% → 3.6%). Strong evidence that Default
   EventEngine worker threads outlive `grpc_shutdown()` and access
   the lib after dlclose.
6. **`SetWaitForSingleOwnerStalledCallback` never fires.** The wait
   inside `ShutdownDefaultEventEngine()` always completes promptly —
   so the race the residual crashes are losing is *not* "EE waiting
   for stragglers." It is "MSHUTDOWN returns, dlclose runs, some
   *other* worker thread is still on the CPU and now its code page
   is gone."
7. **gdb on a residual core shows that exact pattern.** Main thread
   is in `exit() → __cxa_finalize → dl_fini → libresolv fini`. The
   crashing thread has its PC in unmapped memory inside what used to
   be grpc.so's text segment, with the stack trashed because the
   return-address frame pointers also lived in that mapping.
8. **Pinning grpc.so with `RTLD_NODELETE` makes the crashes stop
   entirely.** Adding three lines to `PHP_MINIT_FUNCTION(grpc)` that
   do `dlopen(self, RTLD_LAZY | RTLD_NOLOAD | RTLD_NODELETE)` keeps
   the lib mapped for the rest of the process. Detached worker
   threads that outlive PHP_MSHUTDOWN now still have valid code to
   execute. 0/2000 SEGV (95% CI upper bound ~0.15%).

## gdb forensics

Captured by `forensics.sh` (compose service `php85-lto-forensics`):
the script loops `gdb -batch --args php ... grpc_call.php` until it
catches a SIGSEGV, then dumps `info threads` / `bt` / `info
sharedlibrary` / `x/10i $pc`. Trimmed transcript:

```
Program received signal SIGSEGV, Segmentation fault.
[Switching to Thread 0xffff... (LWP 517)]
0x0000ffff7afdef60 in ?? ()

(gdb) info threads
* 1   Thread 0xffff... (LWP 517)   0x0000ffff7afdef60 in ?? ()
  2   Thread 0xffff... (LWP 503)   __cxa_finalize () at libc

(gdb) thread apply 1 bt
#0  0x0000ffff7afdef60 in ?? ()
Backtrace stopped: previous frame identical to this frame (corrupt stack?)

(gdb) thread apply 2 bt
#0  __cxa_finalize ()
#1  _dl_fini ()
#2  __run_exit_handlers ()
#3  exit ()
#4  main ()

(gdb) info sharedlibrary
   ... libc.so.6 ...
   ... libpthread.so.0 ...
   ... libstdc++.so.6 ...
   (grpc.so is *not* listed — _dl_fini already unmapped it)

(gdb) x/10i $pc
0xffff7afdef60: Cannot access memory at address 0xffff7afdef60
```

Main is mid-`_dl_fini`, the worker's `$pc` lies in what *was* grpc.so's
text mapping, grpc.so is gone from `info sharedlibrary`, and the
kernel can't fetch an instruction from `$pc`. Same shape on every
captured core; only the address inside the unmapped range varies.

With `RTLD_NODELETE`, grpc.so's text stays mapped past `_dl_fini`, so
whatever instruction the worker fetches next is still valid code.

## Why LTO and not the other flags

LTO (whole-program optimization) is the only flag in the set that:

- can change the order in which static initializers run,
- can change the order in which `__cxa_atexit` callbacks register and
  fire,
- can fuse symbols across translation-unit boundaries and prune /
  inline destructors that the gRPC C-core relies on running in a
  specific order,
- can change which symbols become hidden / locally-bound by the LTO
  linker.

The other flags are codegen-time only (or scope-of-visibility only)
and can't reorder cleanup callbacks. Empirically, removing `-flto=auto`
from the same `make` invocation that otherwise has `-O3
-fno-semantic-interposition -march=native` is enough to drop SEGV from
40% → 0%.

## Architecture sensitivity (anecdotal)

The same bad-flag build on an arm64 native run reproduces at ~30–40%.
The same image run under amd64 emulation on the same host gives 0%
in 500 iterations. Whether that's the codegen difference or the
emulation slowdown widening the safe window for worker threads to
finish before shutdown is not resolved here. The fix
(`RTLD_NODELETE`) does not depend on the cause, so it is left as a
TODO for anyone who wants to pin the architecture story.

## Practical recommendations

1. **For downstream image authors:** do not apply `-flto=auto` to
   `grpc.so` when building it as a PHP extension. Excluding grpc from
   any project-wide `EXTRA_CFLAGS=-flto=auto` injection is enough.
2. **For grpc upstream:** consider self-pinning grpc.so with
   `RTLD_NODELETE` (or a `__attribute__((destructor))` that guarantees
   detached workers are joined before the linker is allowed to
   unmap). Detached threads that outlive `dlclose()` are a structural
   problem and any caller can hit it; LTO just made it loud enough to
   notice.
