#include "src/core/lib/event_engine/default_event_engine.h"

extern "C" void grpc_php_shutdown_default_event_engine_for_debug(void) {
  grpc_event_engine::experimental::ShutdownDefaultEventEngine();
}
