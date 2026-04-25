# Images for reproducing the PHP ext-grpc shutdown SIGSEGV when the
# extension is built with -flto=auto.
#
# All targets are based on official Docker Hub `php:*-cli` images and
# install grpc-${GRPC_VERSION} via PECL with various flag combinations.

ARG GRPC_VERSION=1.80.0

#------------------------------------------------------------------------------
# Stock pecl install on each official Docker Hub PHP image. Used as the
# clean baseline (should be 0% SEGV).
#------------------------------------------------------------------------------

FROM php:8.5.5-cli AS php85-debian
ARG GRPC_VERSION
RUN set -eux \
  && apt-get update \
  && apt-get install -y --no-install-recommends $PHPIZE_DEPS zlib1g-dev \
  && pecl install grpc-${GRPC_VERSION} \
  && docker-php-ext-enable grpc \
  && apt-get purge -y --auto-remove $PHPIZE_DEPS \
  && rm -rf /var/lib/apt/lists/*

#------------------------------------------------------------------------------
# Vanilla php:8.5.5-cli + grpc 1.80.0 rebuilt with optimization flags
# injected via EXTRA_CFLAGS at make time. Reproduces the shutdown SIGSEGV.
#
# php85-lto:    full set    -O3 -flto=auto -fno-semantic-interposition -march=native
# php85-ltoonly: only       -flto=auto                                  (cleanest isolation)
# php85-nolto:   drop LTO   -O3 -fno-semantic-interposition -march=native (control)
#------------------------------------------------------------------------------

FROM php:8.5.5-cli AS php85-lto
ARG GRPC_VERSION
ENV LTO_CFLAGS="-O3 -flto=auto -fno-semantic-interposition -march=native"
ENV LTO_LDFLAGS="-flto=auto"
RUN set -eux \
  && apt-get update \
  && apt-get install -y --no-install-recommends $PHPIZE_DEPS zlib1g-dev \
  && pecl download grpc-${GRPC_VERSION} \
  && tar xzf grpc-${GRPC_VERSION}.tgz -C /tmp \
  && cd /tmp/grpc-${GRPC_VERSION} \
  && phpize \
  && ./configure --enable-grpc --enable-option-checking=fatal \
  && make -j"$(nproc)" \
       EXTRA_CFLAGS="${LTO_CFLAGS}" \
       EXTRA_CXXFLAGS="${LTO_CFLAGS}" \
       EXTRA_LDFLAGS="${LTO_LDFLAGS}" \
  && make install \
       EXTRA_CFLAGS="${LTO_CFLAGS}" \
       EXTRA_CXXFLAGS="${LTO_CFLAGS}" \
       EXTRA_LDFLAGS="${LTO_LDFLAGS}" \
  && docker-php-ext-enable grpc \
  && rm -rf /tmp/grpc-* \
  && apt-get purge -y --auto-remove $PHPIZE_DEPS \
  && rm -rf /var/lib/apt/lists/*

FROM php:8.5.5-cli AS php85-ltoonly
ARG GRPC_VERSION
ENV LTO_CFLAGS="-flto=auto"
ENV LTO_LDFLAGS="-flto=auto"
RUN set -eux \
  && apt-get update \
  && apt-get install -y --no-install-recommends $PHPIZE_DEPS zlib1g-dev \
  && pecl download grpc-${GRPC_VERSION} \
  && tar xzf grpc-${GRPC_VERSION}.tgz -C /tmp \
  && cd /tmp/grpc-${GRPC_VERSION} \
  && phpize \
  && ./configure --enable-grpc --enable-option-checking=fatal \
  && make -j"$(nproc)" \
       EXTRA_CFLAGS="${LTO_CFLAGS}" \
       EXTRA_CXXFLAGS="${LTO_CFLAGS}" \
       EXTRA_LDFLAGS="${LTO_LDFLAGS}" \
  && make install \
       EXTRA_CFLAGS="${LTO_CFLAGS}" \
       EXTRA_CXXFLAGS="${LTO_CFLAGS}" \
       EXTRA_LDFLAGS="${LTO_LDFLAGS}" \
  && docker-php-ext-enable grpc \
  && rm -rf /tmp/grpc-* \
  && apt-get purge -y --auto-remove $PHPIZE_DEPS \
  && rm -rf /var/lib/apt/lists/*

FROM php:8.5.5-cli AS php85-nolto
ARG GRPC_VERSION
ENV LTO_CFLAGS="-O3 -fno-semantic-interposition -march=native"
ENV LTO_LDFLAGS=""
RUN set -eux \
  && apt-get update \
  && apt-get install -y --no-install-recommends $PHPIZE_DEPS zlib1g-dev \
  && pecl download grpc-${GRPC_VERSION} \
  && tar xzf grpc-${GRPC_VERSION}.tgz -C /tmp \
  && cd /tmp/grpc-${GRPC_VERSION} \
  && phpize \
  && ./configure --enable-grpc --enable-option-checking=fatal \
  && make -j"$(nproc)" \
       EXTRA_CFLAGS="${LTO_CFLAGS}" \
       EXTRA_CXXFLAGS="${LTO_CFLAGS}" \
       EXTRA_LDFLAGS="${LTO_LDFLAGS}" \
  && make install \
       EXTRA_CFLAGS="${LTO_CFLAGS}" \
       EXTRA_CXXFLAGS="${LTO_CFLAGS}" \
       EXTRA_LDFLAGS="${LTO_LDFLAGS}" \
  && docker-php-ext-enable grpc \
  && rm -rf /tmp/grpc-* \
  && apt-get purge -y --auto-remove $PHPIZE_DEPS \
  && rm -rf /var/lib/apt/lists/*

#------------------------------------------------------------------------------
# Experiment 1A: replace grpc_shutdown() in PHP_MSHUTDOWN_FUNCTION(grpc)
# with grpc_shutdown_blocking(). LTO-only build, no other patches.
# Tests whether MSHUTDOWN returning before grpc background work finishes
# is the trigger.
#------------------------------------------------------------------------------

FROM php:8.5.5-cli AS php85-lto-shutdownblocking
ARG GRPC_VERSION
ENV LTO_CFLAGS="-flto=auto"
ENV LTO_LDFLAGS="-flto=auto"
RUN set -eux \
  && apt-get update \
  && apt-get install -y --no-install-recommends $PHPIZE_DEPS zlib1g-dev \
  && pecl download grpc-${GRPC_VERSION} \
  && tar xzf grpc-${GRPC_VERSION}.tgz -C /tmp \
  && cd /tmp/grpc-${GRPC_VERSION} \
  # Replace grpc_shutdown() with grpc_shutdown_blocking() ONLY inside
  # PHP_MSHUTDOWN_FUNCTION(grpc) { ... } block.
  && sed -i '/^PHP_MSHUTDOWN_FUNCTION(grpc)/,/^}/{s/grpc_shutdown();/grpc_shutdown_blocking();/}' \
       src/php/ext/grpc/php_grpc.c \
  && grep -n "grpc_shutdown" src/php/ext/grpc/php_grpc.c \
  && phpize \
  && ./configure --enable-grpc --enable-option-checking=fatal \
  && make -j"$(nproc)" \
       EXTRA_CFLAGS="${LTO_CFLAGS}" \
       EXTRA_CXXFLAGS="${LTO_CFLAGS}" \
       EXTRA_LDFLAGS="${LTO_LDFLAGS}" \
  && make install \
       EXTRA_CFLAGS="${LTO_CFLAGS}" \
       EXTRA_CXXFLAGS="${LTO_CFLAGS}" \
       EXTRA_LDFLAGS="${LTO_LDFLAGS}" \
  && docker-php-ext-enable grpc \
  && rm -rf /tmp/grpc-* \
  && apt-get purge -y --auto-remove $PHPIZE_DEPS \
  && rm -rf /var/lib/apt/lists/*

#------------------------------------------------------------------------------
# Experiment 1B: keep grpc_shutdown() then call
# grpc_maybe_wait_for_async_shutdown() right after. LTO-only build.
# init.h is C++ so we add a tiny extern-"C" bridge .cc and patch config.m4
# to compile it.
#------------------------------------------------------------------------------

FROM php:8.5.5-cli AS php85-lto-waitforasync
ARG GRPC_VERSION
ENV LTO_CFLAGS="-flto=auto"
ENV LTO_LDFLAGS="-flto=auto"
RUN set -eux \
  && apt-get update \
  && apt-get install -y --no-install-recommends $PHPIZE_DEPS zlib1g-dev \
  && pecl download grpc-${GRPC_VERSION} \
  && tar xzf grpc-${GRPC_VERSION}.tgz -C /tmp \
  && cd /tmp/grpc-${GRPC_VERSION} \
  # Add bridge .cc that exposes the internal symbol with C linkage
  && printf '%s\n' \
       '#include "src/core/lib/surface/init.h"' \
       '' \
       'extern "C" void grpc_php_maybe_wait_for_async_shutdown(void) {' \
       '  grpc_maybe_wait_for_async_shutdown();' \
       '}' \
       > src/php/ext/grpc/php_grpc_shutdown_bridge.cc \
  # Patch root config.m4 to compile the bridge alongside php_grpc.c
  && sed -i 's|src/php/ext/grpc/php_grpc.c \\|src/php/ext/grpc/php_grpc.c \\\n    src/php/ext/grpc/php_grpc_shutdown_bridge.cc \\|' \
       config.m4 \
  # Patch php_grpc.c: declare bridge + call right after grpc_shutdown() in MSHUTDOWN
  && sed -i '0,/^#include "php_grpc.h"$/{s|^#include "php_grpc.h"$|#include "php_grpc.h"\nextern void grpc_php_maybe_wait_for_async_shutdown(void);|}' \
       src/php/ext/grpc/php_grpc.c \
  && sed -i '/^PHP_MSHUTDOWN_FUNCTION(grpc)/,/^}/{s/grpc_shutdown();/grpc_shutdown(); grpc_php_maybe_wait_for_async_shutdown();/}' \
       src/php/ext/grpc/php_grpc.c \
  && grep -n "grpc_shutdown\|grpc_php_maybe" src/php/ext/grpc/php_grpc.c | head -10 \
  && grep -n "php_grpc_shutdown_bridge\|php_grpc.c" config.m4 | head \
  && phpize \
  && ./configure --enable-grpc --enable-option-checking=fatal \
  && make -j"$(nproc)" \
       EXTRA_CFLAGS="${LTO_CFLAGS}" \
       EXTRA_CXXFLAGS="${LTO_CFLAGS}" \
       EXTRA_LDFLAGS="${LTO_LDFLAGS}" \
  && make install \
       EXTRA_CFLAGS="${LTO_CFLAGS}" \
       EXTRA_CXXFLAGS="${LTO_CFLAGS}" \
       EXTRA_LDFLAGS="${LTO_LDFLAGS}" \
  && docker-php-ext-enable grpc \
  && rm -rf /tmp/grpc-* \
  && apt-get purge -y --auto-remove $PHPIZE_DEPS \
  && rm -rf /var/lib/apt/lists/*

#------------------------------------------------------------------------------
# Experiment 2: explicitly ShutdownDefaultEventEngine() from MSHUTDOWN. If
# the race is about Default EventEngine workers outliving grpc_shutdown(),
# this should make it disappear. Bridge .cc lets us call the C++-only API
# from the C MSHUTDOWN.
#------------------------------------------------------------------------------

FROM php:8.5.5-cli AS php85-lto-shutdownee
ARG GRPC_VERSION
ENV LTO_CFLAGS="-flto=auto"
ENV LTO_LDFLAGS="-flto=auto"
RUN set -eux \
  && apt-get update \
  && apt-get install -y --no-install-recommends $PHPIZE_DEPS zlib1g-dev \
  && pecl download grpc-${GRPC_VERSION} \
  && tar xzf grpc-${GRPC_VERSION}.tgz -C /tmp \
  && cd /tmp/grpc-${GRPC_VERSION} \
  && printf '%s\n' \
       '#include "src/core/lib/event_engine/default_event_engine.h"' \
       '' \
       'extern "C" void grpc_php_shutdown_default_event_engine_for_debug(void) {' \
       '  grpc_event_engine::experimental::ShutdownDefaultEventEngine();' \
       '}' \
       > src/php/ext/grpc/php_grpc_shutdown_bridge.cc \
  && sed -i 's|src/php/ext/grpc/php_grpc.c \\|src/php/ext/grpc/php_grpc.c \\\n    src/php/ext/grpc/php_grpc_shutdown_bridge.cc \\|' \
       config.m4 \
  && sed -i '0,/^#include "php_grpc.h"$/{s|^#include "php_grpc.h"$|#include "php_grpc.h"\nextern void grpc_php_shutdown_default_event_engine_for_debug(void);|}' \
       src/php/ext/grpc/php_grpc.c \
  && sed -i '/^PHP_MSHUTDOWN_FUNCTION(grpc)/,/^}/{s/grpc_shutdown();/grpc_shutdown(); grpc_php_shutdown_default_event_engine_for_debug();/}' \
       src/php/ext/grpc/php_grpc.c \
  && grep -n "grpc_shutdown\|grpc_php_shutdown_default" src/php/ext/grpc/php_grpc.c | head \
  && phpize \
  && ./configure --enable-grpc --enable-option-checking=fatal \
  && make -j"$(nproc)" \
       EXTRA_CFLAGS="${LTO_CFLAGS}" \
       EXTRA_CXXFLAGS="${LTO_CFLAGS}" \
       EXTRA_LDFLAGS="${LTO_LDFLAGS}" \
  && make install \
       EXTRA_CFLAGS="${LTO_CFLAGS}" \
       EXTRA_CXXFLAGS="${LTO_CFLAGS}" \
       EXTRA_LDFLAGS="${LTO_LDFLAGS}" \
  && docker-php-ext-enable grpc \
  && rm -rf /tmp/grpc-* \
  && apt-get purge -y --auto-remove $PHPIZE_DEPS \
  && rm -rf /var/lib/apt/lists/*

#------------------------------------------------------------------------------
# Experiment 3: same as shutdownee, but install
# SetWaitForSingleOwnerStalledCallback first and write a marker to stderr if
# the wait stalls. Tells us whether someone is still holding a shared ref to
# the EventEngine when we try to tear it down.
#------------------------------------------------------------------------------

FROM php:8.5.5-cli AS php85-lto-shutdownee-stalled
ARG GRPC_VERSION
ENV LTO_CFLAGS="-flto=auto"
ENV LTO_LDFLAGS="-flto=auto"
RUN set -eux \
  && apt-get update \
  && apt-get install -y --no-install-recommends $PHPIZE_DEPS zlib1g-dev \
  && pecl download grpc-${GRPC_VERSION} \
  && tar xzf grpc-${GRPC_VERSION}.tgz -C /tmp \
  && cd /tmp/grpc-${GRPC_VERSION} \
  && printf '%s\n' \
       '#include <cstdio>' \
       '#include "src/core/lib/event_engine/default_event_engine.h"' \
       '#include "src/core/util/wait_for_single_owner.h"' \
       '' \
       'extern "C" void grpc_php_shutdown_default_event_engine_for_debug(void) {' \
       '  grpc_core::SetWaitForSingleOwnerStalledCallback([]() {' \
       '    fprintf(stderr, "[grpc-segv-debug] WaitForSingleOwner stalled\\n");' \
       '  });' \
       '  grpc_event_engine::experimental::ShutdownDefaultEventEngine();' \
       '}' \
       > src/php/ext/grpc/php_grpc_shutdown_bridge.cc \
  && sed -i 's|src/php/ext/grpc/php_grpc.c \\|src/php/ext/grpc/php_grpc.c \\\n    src/php/ext/grpc/php_grpc_shutdown_bridge.cc \\|' \
       config.m4 \
  && sed -i '0,/^#include "php_grpc.h"$/{s|^#include "php_grpc.h"$|#include "php_grpc.h"\nextern void grpc_php_shutdown_default_event_engine_for_debug(void);|}' \
       src/php/ext/grpc/php_grpc.c \
  && sed -i '/^PHP_MSHUTDOWN_FUNCTION(grpc)/,/^}/{s/grpc_shutdown();/grpc_shutdown(); grpc_php_shutdown_default_event_engine_for_debug();/}' \
       src/php/ext/grpc/php_grpc.c \
  && phpize \
  && ./configure --enable-grpc --enable-option-checking=fatal \
  && make -j"$(nproc)" \
       EXTRA_CFLAGS="${LTO_CFLAGS}" \
       EXTRA_CXXFLAGS="${LTO_CFLAGS}" \
       EXTRA_LDFLAGS="${LTO_LDFLAGS}" \
  && make install \
       EXTRA_CFLAGS="${LTO_CFLAGS}" \
       EXTRA_CXXFLAGS="${LTO_CFLAGS}" \
       EXTRA_LDFLAGS="${LTO_LDFLAGS}" \
  && docker-php-ext-enable grpc \
  && rm -rf /tmp/grpc-* \
  && apt-get purge -y --auto-remove $PHPIZE_DEPS \
  && rm -rf /var/lib/apt/lists/*

#------------------------------------------------------------------------------
# RTLD_NODELETE workaround: vanilla PHP + grpc 1.80.0 + ONLY -flto=auto
# (= the LTO trigger) + patch php_grpc.c so grpc.so re-dlopens itself with
# RTLD_NOLOAD|RTLD_NODELETE during MINIT. PHP's later dlclose then can't
# unmap the lib, so any worker thread still running at process exit keeps
# valid code pointers and we avoid the shutdown SEGV race entirely.
#------------------------------------------------------------------------------

FROM php:8.5.5-cli AS php85-lto-nodelete
ARG GRPC_VERSION
ENV LTO_CFLAGS="-flto=auto"
ENV LTO_LDFLAGS="-flto=auto"
RUN set -eux \
  && apt-get update \
  && apt-get install -y --no-install-recommends $PHPIZE_DEPS zlib1g-dev \
  && pecl download grpc-${GRPC_VERSION} \
  && tar xzf grpc-${GRPC_VERSION}.tgz -C /tmp \
  && cd /tmp/grpc-${GRPC_VERSION} \
  # Add a tiny pinning helper that re-dlopens self with RTLD_NODELETE.
  && printf '%s\n' \
       '#include <dlfcn.h>' \
       '' \
       'static int grpc_php_nodelete_anchor = 0;' \
       '' \
       'void grpc_php_pin_self_with_nodelete(void) {' \
       '  Dl_info info;' \
       '  if (dladdr(&grpc_php_nodelete_anchor, &info) && info.dli_fname) {' \
       '    void *h = dlopen(info.dli_fname,' \
       '                     RTLD_LAZY | RTLD_NOLOAD | RTLD_NODELETE);' \
       '    (void)h; /* discard; NODELETE flag is now set on the loaded lib */' \
       '  }' \
       '}' \
       > src/php/ext/grpc/php_grpc_pin_self.c \
  && sed -i 's|src/php/ext/grpc/php_grpc.c \\|src/php/ext/grpc/php_grpc.c \\\n    src/php/ext/grpc/php_grpc_pin_self.c \\|' \
       config.m4 \
  # Forward-declare and call the pin from PHP_MINIT_FUNCTION(grpc) right at
  # the top, before any grpc init.
  && sed -i '0,/^#include "php_grpc.h"$/{s|^#include "php_grpc.h"$|#include "php_grpc.h"\nextern void grpc_php_pin_self_with_nodelete(void);|}' \
       src/php/ext/grpc/php_grpc.c \
  && sed -i '/^PHP_MINIT_FUNCTION(grpc)/,/^}/{0,/{$/{s|{$|{ grpc_php_pin_self_with_nodelete();|}}' \
       src/php/ext/grpc/php_grpc.c \
  && grep -n "grpc_php_pin_self\|PHP_MINIT_FUNCTION(grpc)" src/php/ext/grpc/php_grpc.c | head \
  && phpize \
  && ./configure --enable-grpc --enable-option-checking=fatal \
  && make -j"$(nproc)" \
       EXTRA_CFLAGS="${LTO_CFLAGS}" \
       EXTRA_CXXFLAGS="${LTO_CFLAGS}" \
       EXTRA_LDFLAGS="${LTO_LDFLAGS}" \
  && make install \
       EXTRA_CFLAGS="${LTO_CFLAGS}" \
       EXTRA_CXXFLAGS="${LTO_CFLAGS}" \
       EXTRA_LDFLAGS="${LTO_LDFLAGS}" \
  && docker-php-ext-enable grpc \
  && rm -rf /tmp/grpc-* \
  && apt-get purge -y --auto-remove $PHPIZE_DEPS \
  && rm -rf /var/lib/apt/lists/*

#------------------------------------------------------------------------------
# Forensics target: same build as php85-ltoonly (-flto=auto only), but ships
# gdb so forensics.sh can run grpc_call.php under gdb in batch mode and dump
# threads / backtraces / proc mappings / sharedlibrary list at SIGSEGV time.
#------------------------------------------------------------------------------

FROM php:8.5.5-cli AS php85-lto-forensics
ARG GRPC_VERSION
ENV LTO_CFLAGS="-flto=auto"
ENV LTO_LDFLAGS="-flto=auto"
RUN set -eux \
  && apt-get update \
  && apt-get install -y --no-install-recommends $PHPIZE_DEPS zlib1g-dev \
  && pecl download grpc-${GRPC_VERSION} \
  && tar xzf grpc-${GRPC_VERSION}.tgz -C /tmp \
  && cd /tmp/grpc-${GRPC_VERSION} \
  && phpize \
  && ./configure --enable-grpc --enable-option-checking=fatal \
  && make -j"$(nproc)" \
       EXTRA_CFLAGS="${LTO_CFLAGS}" \
       EXTRA_CXXFLAGS="${LTO_CFLAGS}" \
       EXTRA_LDFLAGS="${LTO_LDFLAGS}" \
  && make install \
       EXTRA_CFLAGS="${LTO_CFLAGS}" \
       EXTRA_CXXFLAGS="${LTO_CFLAGS}" \
       EXTRA_LDFLAGS="${LTO_LDFLAGS}" \
  && docker-php-ext-enable grpc \
  && rm -rf /tmp/grpc-* \
  && apt-get purge -y --auto-remove $PHPIZE_DEPS \
  && apt-get install -y --no-install-recommends gdb \
  && rm -rf /var/lib/apt/lists/*
