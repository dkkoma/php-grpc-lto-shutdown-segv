#include "src/core/lib/surface/init.h"

extern "C" void grpc_php_maybe_wait_for_async_shutdown(void) {
  grpc_maybe_wait_for_async_shutdown();
}
