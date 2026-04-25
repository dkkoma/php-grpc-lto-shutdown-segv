# PHP ext-grpc shutdown SIGSEGV when built with `-flto=auto`

Standalone reproducer and bisection harness for an intermittent
shutdown-time SIGSEGV in the PHP gRPC extension (grpc 1.80.0) when the
extension is built with **Link Time Optimization (`-flto=auto`)**.

## TL;DR

- Building `pecl install grpc-1.80.0` on a vanilla `php:8.5.5-cli` with
  extra `-flto=auto` (and nothing else) injected via
  `EXTRA_CFLAGS / EXTRA_CXXFLAGS / EXTRA_LDFLAGS` reproduces ~30–40%
  SIGSEGV at process shutdown on a tiny `Grpc\Channel + Grpc\Call`
  snippet (no SDK, no framework, no composer).
- Building the same source without LTO is 0/500.
- `grpc_shutdown_blocking()` and `grpc_maybe_wait_for_async_shutdown()`
  do **not** mitigate.
- Explicitly calling `grpc_event_engine::experimental::ShutdownDefaultEventEngine()`
  from `PHP_MSHUTDOWN` reduces it to ~3–4% — the residual is non-EE
  worker threads (DNS resolver / iomgr-ish) outliving the dlclose.
- `dlopen(self, RTLD_NOLOAD | RTLD_NODELETE)` self-pin in `PHP_MINIT`
  brings it to **0/2000**: the actual code pages stay mapped past
  `dl_fini`, so any worker thread still alive at process exit keeps a
  valid program counter.

Detailed evidence and a full bisection log lives in [`NOTES.md`](./NOTES.md).

## Why this matters

`-flto=auto` is a normal-looking optimization flag. Anyone who builds
PHP shared extensions with whole-program LTO injected via
`EXTRA_CFLAGS / EXTRA_LDFLAGS` (e.g. via a custom
`docker-php-pecl-install` wrapper) ends up with a `grpc.so` that
crashes intermittently at PHP shutdown. The same source built without
LTO is fine.

## Reproduction

### Prerequisites

- Docker / Docker Compose
- ARM64 (Apple Silicon under OrbStack) reproduces at ~30%; AMD64 may
  reproduce at a different rate (see "Architecture sensitivity" in
  NOTES.md).

### Quick start

```sh
# 1. The clean baseline – stock pecl install. Should be 0 crashes.
docker compose run --rm -e N=500 php85-debian

# 2. Same source + ONLY -flto=auto. ~30% SIGSEGV.
docker compose build php85-ltoonly
docker compose run --rm -e N=500 php85-ltoonly

# 3. Add RTLD_NODELETE self-pin in MINIT. Back to 0.
docker compose build php85-lto-nodelete
docker compose run --rm -e N=2000 php85-lto-nodelete
```

`loop.sh` runs `php -n -d extension=grpc grpc_call.php` `N` times in a
single container (no per-iteration container startup) and prints
`segv=<count> ok=<count>`.

### Available services

The shutdownee experiments listed below all keep `-flto=auto` and
toggle the patch under test, so each gives a clean answer to "does
*this* mitigation alone fix it?".

| service                            | what it builds                                                                |
|------------------------------------|-------------------------------------------------------------------------------|
| `php85-debian`                     | vanilla `php:8.5.5-cli` + `pecl install grpc-1.80.0` (no extra flags)         |
| `php85-lto`                        | full set: `-O3 -flto=auto -fno-semantic-interposition -march=native`          |
| `php85-nolto`                      | drop `-flto=auto`, keep the rest – 0% (LTO bisect)                            |
| `php85-ltoonly`                    | only `-flto=auto`, nothing else – ~30%                                        |
| `php85-lto-shutdownblocking`       | LTO + `grpc_shutdown_blocking()` instead of `grpc_shutdown()` in MSHUTDOWN    |
| `php85-lto-waitforasync`           | LTO + `grpc_shutdown(); grpc_maybe_wait_for_async_shutdown();` (C++ bridge)   |
| `php85-lto-shutdownee`             | LTO + `ShutdownDefaultEventEngine()` from MSHUTDOWN (C++ bridge)              |
| `php85-lto-shutdownee-stalled`     | shutdownee + `SetWaitForSingleOwnerStalledCallback` instrumentation           |
| `php85-lto-nodelete`               | LTO + `dlopen(self, RTLD_NOLOAD\|RTLD_NODELETE)` in MINIT                     |
| `php85-lto-forensics`              | same as `php85-ltoonly`, plus `gdb`; runs `forensics.sh` to capture a SIGSEGV |

### What `grpc_call.php` does

It is the smallest possible code that triggers the race:

```php
<?php
$channel  = new Grpc\Channel('spanner-emulator:9010', [
    'credentials' => Grpc\ChannelCredentials::createInsecure(),
]);
$deadline = Grpc\Timeval::now()->add(new Grpc\Timeval(5 * 1000 * 1000));
$call = new Grpc\Call(
    $channel,
    '/google.spanner.admin.instance.v1.InstanceAdmin/ListInstanceConfigs',
    $deadline,
);
$call->startBatch([
    Grpc\OP_SEND_INITIAL_METADATA  => [],
    Grpc\OP_SEND_MESSAGE           => ['message' => "\x0a\x16projects/repro-project"],
    Grpc\OP_SEND_CLOSE_FROM_CLIENT => true,
    Grpc\OP_RECV_INITIAL_METADATA  => true,
    Grpc\OP_RECV_MESSAGE           => true,
    Grpc\OP_RECV_STATUS_ON_CLIENT  => true,
]);
```

No SDK, no composer autoload, no protobuf library – the request body
is hand-encoded protobuf for `ListInstanceConfigsRequest{parent="projects/repro-project"}`.
The Spanner emulator is just a convenient gRPC server with a real
handler that returns 200/OK; any other gRPC server with a real handler
should work the same way.

## Result summary

See [`NOTES.md`](./NOTES.md) for the full matrix and chronological
investigation. The headline numbers on Apple Silicon arm64 / OrbStack:

| build                                                                  | SEGV / total | rate  |
|------------------------------------------------------------------------|--------------|-------|
| stock pecl, no extra flags                                             | 0 / 500      | 0%    |
| `-O3 -fno-semantic-interposition -march=native` (no LTO)               | 0 / 500      | 0%    |
| `-flto=auto` only                                                      | 169 / 500    | 33.8% |
| `-O3 -flto=auto -fno-semantic-interposition -march=native`             | 202 / 500    | 40.4% |
| LTO + `grpc_shutdown_blocking()`                                       | 160 / 500    | 32.0% |
| LTO + `grpc_maybe_wait_for_async_shutdown()`                           | 166 / 500    | 33.2% |
| LTO + `ShutdownDefaultEventEngine()`                                   | 18 / 500     | 3.6%  |
| **LTO + `RTLD_NODELETE` self-pin**                                     | **0 / 2000** | **0%**|

## Root cause

The evidence is consistent with `-flto=auto` changing teardown ordering
or lifetime timing inside grpc.so — whole-program optimization can in
principle reorder / merge static initialisers and `__cxa_atexit`
registrations across translation units, prune or inline destructors,
and change symbol visibility. We have not pinned down the specific
mechanism, but empirically: with LTO some background-worker tear-down
does not finish by the time `PHP_MSHUTDOWN_FUNCTION(grpc)` returns. PHP
then calls `dlclose(grpc.so)`; the dynamic linker drops the refcount,
the lib gets `munmap`'d at `dl_fini`, and any thread still executing
grpc.so code at that instant takes a SIGSEGV with `RIP` in unmapped
memory.

`grpc_shutdown()` /`grpc_shutdown_blocking()` /
`grpc_maybe_wait_for_async_shutdown()` all complete cleanly without
stalling — that is, they don't notice anything is still running — yet a
worker thread is still on the CPU at `dl_fini` time. Calling
`ShutdownDefaultEventEngine()` explicitly catches one class of those
threads (the WorkStealingThreadPool fronting the EventEngine), which
is why it drops the rate by ~10x. The remaining ~3–4% are other
internal owners (DNS resolver, iomgr listener, completion-queue
callback threads). gdb on the residual cores shows main thread inside
`__cxa_finalize → dl_fini → libresolv.so.2 fini` while a second
thread's PC is in unmapped grpc.so address range — exactly the dlclose
race.

## Practical fixes

1. **Don't apply `-flto=auto` to grpc.so.** The non-LTO build is a
   straight 0%. This is the lowest-risk fix for image / build-system
   maintainers.
2. **`RTLD_NODELETE` self-pin** in grpc.so's `MINIT`. Three lines of C:
   ```c
   Dl_info info;
   if (dladdr((void*)&some_symbol_in_grpc_so, &info) && info.dli_fname) {
       dlopen(info.dli_fname, RTLD_LAZY | RTLD_NOLOAD | RTLD_NODELETE);
   }
   ```
   This keeps the `text` mapping alive for the rest of the process so
   the worker threads always have valid code to execute. The lib's
   ~10 MB stays resident until `exit(2)`.

(1) is preferable upstream. (2) is the defense-in-depth that a library
known to spawn detached worker threads should already have, regardless
of caller flags.

## CI

`.github/workflows/repro.yml` runs every service in the compose
matrix on both `ubuntu-latest` (x86_64) and `ubuntu-24.04-arm`
(aarch64) GitHub-hosted runners. The workflow does not assert any
particular SEGV count — it just runs each service and renders a
NOTES-style table to the run's `$GITHUB_STEP_SUMMARY`:

```
| service                        | x86_64           | aarch64         |
|--------------------------------|------------------|-----------------|
| php85-debian                   | 0 / 200 (0.0%)   | 0 / 200 (0.0%)  |
| php85-ltoonly                  | …                | …               |
| php85-lto-nodelete             | 0 / 200 (0.0%)   | 0 / 200 (0.0%)  |
| ...                            | ...              | ...             |
```

Trigger via `workflow_dispatch` or push/PR. Default `N=1000` per cell;
pass `n` as input to override.

## Status / scope

This repo is a single self-contained reproducer. No fix is being
shipped here — the sample code under `php85-lto-nodelete` is for
demonstrating the workaround, not as production code. File issues /
PRs against grpc upstream if you want a real fix.
