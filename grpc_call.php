<?php
// Minimal reproducer for a shutdown-time SIGSEGV in ext-grpc on PHP 8.5.
//
// Sends a single raw unary gRPC call using the ext-grpc primitives only —
// no composer autoload, no client SDK, no protobuf library. Enough to spin
// up the C-core EventEngine workers so the shutdown race can fire.
//
// The call target is Spanner Emulator's InstanceAdmin.ListInstanceConfigs,
// which the emulator fully implements and returns a real response for
// (code=OK with the emulator-config entry). The request body is a
// hand-encoded protobuf equivalent of:
//
//   ListInstanceConfigsRequest { parent = "projects/repro-project"; }
//
// Env:
//   GRPC_TARGET   target host:port (default: spanner-emulator:9010)

$target = getenv('GRPC_TARGET') ?: 'spanner-emulator:9010';

$parent = 'projects/repro-project';

// Wire format: field 1 (parent, string), tag 0x0a + varint length + bytes
$request = "\x0a" . chr(strlen($parent)) . $parent;

$channel  = new Grpc\Channel($target, [
    'credentials' => Grpc\ChannelCredentials::createInsecure(),
]);
// Grpc\Timeval::add() returns a new Timeval; capture it.
$deadline = Grpc\Timeval::now()->add(new Grpc\Timeval(5 * 1000 * 1000)); // 5s

$call = new Grpc\Call(
    $channel,
    '/google.spanner.admin.instance.v1.InstanceAdmin/ListInstanceConfigs',
    $deadline,
);

$call->startBatch([
    Grpc\OP_SEND_INITIAL_METADATA  => [],
    Grpc\OP_SEND_MESSAGE           => ['message' => $request],
    Grpc\OP_SEND_CLOSE_FROM_CLIENT => true,
    Grpc\OP_RECV_INITIAL_METADATA  => true,
    Grpc\OP_RECV_MESSAGE           => true,
    Grpc\OP_RECV_STATUS_ON_CLIENT  => true,
]);
