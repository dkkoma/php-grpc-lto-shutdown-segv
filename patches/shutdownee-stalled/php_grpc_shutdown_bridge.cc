#include <cstdio>
#include "src/core/lib/event_engine/default_event_engine.h"
#include "src/core/util/wait_for_single_owner.h"

extern "C" void grpc_php_shutdown_default_event_engine_for_debug(void) {
  grpc_core::SetWaitForSingleOwnerStalledCallback([]() {
    fprintf(stderr, "[grpc-segv-debug] WaitForSingleOwner stalled\n");
  });
  grpc_event_engine::experimental::ShutdownDefaultEventEngine();
}
