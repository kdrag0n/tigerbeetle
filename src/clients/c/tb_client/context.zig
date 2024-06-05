const std = @import("std");
const os = std.os;
const assert = std.debug.assert;

const Atomic = std.atomic.Atomic;

const constants = @import("../../../constants.zig");
const log = std.log.scoped(.tb_client_context);

const stdx = @import("../../../stdx.zig");
const vsr = @import("../../../vsr.zig");
const Header = vsr.Header;

const IO = @import("../../../io.zig").IO;
const FIFO = @import("../../../fifo.zig").FIFO;
const message_pool = @import("../../../message_pool.zig");

const MessagePool = message_pool.MessagePool;
const Message = MessagePool.Message;
const Packet = @import("packet.zig").Packet;
const Signal = @import("signal.zig").Signal;

const api = @import("../tb_client.zig");
const tb_status_t = api.tb_status_t;
const tb_client_t = api.tb_client_t;
const tb_completion_t = api.tb_completion_t;

pub const ContextImplementation = struct {
    completion_ctx: usize,
    acquire_packet_fn: *const fn (*ContextImplementation, out: *?*Packet) PacketAcquireStatus,
    release_packet_fn: *const fn (*ContextImplementation, *Packet) void,
    submit_fn: *const fn (*ContextImplementation, *Packet) void,
    deinit_fn: *const fn (*ContextImplementation) void,
};

pub const Error = std.mem.Allocator.Error || error{
    Unexpected,
    AddressInvalid,
    AddressLimitExceeded,
    ConcurrencyMaxInvalid,
    SystemResources,
    NetworkSubsystemFailed,
};

pub const PacketAcquireStatus = enum(c_int) {
    ok = 0,
    concurrency_max_exceeded,
    shutdown,
};

pub fn ContextType(
    comptime Client: type,
) type {
    return struct {
        const Context = @This();

        const StateMachine = Client.StateMachine;
        const UserData = extern struct {
            self: *Context,
            packet: *Packet,
        };

        comptime {
            assert(@sizeOf(UserData) == @sizeOf(u128));
        }

        fn operation_event_size(op: u8) ?usize {
            const allowed_operations = [_]Client.StateMachine.Operation{
                .create_accounts,
                .create_transfers,
                .import_accounts,
                .import_transfers,
                .lookup_accounts,
                .lookup_transfers,
                .get_account_transfers,
                .get_account_balances,
            };
            inline for (allowed_operations) |operation| {
                if (op == @intFromEnum(operation)) {
                    return @sizeOf(Client.StateMachine.Event(operation));
                }
            }
            return null;
        }

        const PacketError = error{
            TooMuchData,
            InvalidOperation,
            InvalidDataSize,
        };

        allocator: std.mem.Allocator,
        client_id: u128,
        packets: []Packet,
        packets_free: Packet.ConcurrentStack,

        addresses: []const std.net.Address,
        io: IO,
        message_pool: MessagePool,
        client: Client,
        registered: bool,

        completion_fn: tb_completion_t,
        implementation: ContextImplementation,

        signal: Signal,
        submitted: Packet.SubmissionStack,
        pending: FIFO(Packet),
        shutdown: Atomic(bool),
        thread: std.Thread,

        pub fn init(
            allocator: std.mem.Allocator,
            cluster_id: u128,
            addresses: []const u8,
            concurrency_max: u32,
            completion_ctx: usize,
            completion_fn: tb_completion_t,
        ) Error!*Context {
            var context = try allocator.create(Context);
            errdefer allocator.destroy(context);

            context.allocator = allocator;
            context.client_id = std.crypto.random.int(u128);
            assert(context.client_id != 0); // Broken CSPRNG is the likeliest explanation for zero.

            log.debug("{}: init: initializing", .{context.client_id});

            // Arbitrary limit: To take advantage of batching, the `concurrency_max` should be set
            // high enough to allow concurrent requests to completely fill the message body.
            if (concurrency_max == 0 or concurrency_max > 8192) {
                return error.ConcurrencyMaxInvalid;
            }

            log.debug("{}: init: allocating tb_packets", .{context.client_id});
            context.packets = try context.allocator.alloc(Packet, concurrency_max);
            errdefer context.allocator.free(context.packets);

            context.packets_free = .{};
            for (context.packets) |*packet| {
                context.packets_free.push(packet);
            }

            log.debug("{}: init: parsing vsr addresses: {s}", .{ context.client_id, addresses });
            context.addresses = vsr.parse_addresses(
                context.allocator,
                addresses,
                constants.replicas_max,
            ) catch |err| return switch (err) {
                error.AddressLimitExceeded => error.AddressLimitExceeded,
                else => error.AddressInvalid,
            };
            errdefer context.allocator.free(context.addresses);

            log.debug("{}: init: initializing IO", .{context.client_id});
            context.io = IO.init(32, 0) catch |err| {
                log.err("{}: failed to initialize IO: {s}", .{
                    context.client_id,
                    @errorName(err),
                });
                return switch (err) {
                    error.ProcessFdQuotaExceeded => error.SystemResources,
                    error.Unexpected => error.Unexpected,
                    else => unreachable,
                };
            };
            errdefer context.io.deinit();

            log.debug("{}: init: initializing MessagePool", .{context.client_id});
            context.message_pool = try MessagePool.init(allocator, .client);
            errdefer context.message_pool.deinit(context.allocator);

            log.debug("{}: init: initializing client (cluster_id={x:0>32}, addresses={any})", .{
                context.client_id,
                cluster_id,
                context.addresses,
            });
            context.client = try Client.init(
                allocator,
                context.client_id,
                cluster_id,
                @intCast(context.addresses.len),
                &context.message_pool,
                .{
                    .configuration = context.addresses,
                    .io = &context.io,
                },
            );
            errdefer context.client.deinit(context.allocator);

            context.completion_fn = completion_fn;
            context.implementation = .{
                .completion_ctx = completion_ctx,
                .acquire_packet_fn = Context.on_acquire_packet,
                .release_packet_fn = Context.on_release_packet,
                .submit_fn = Context.on_submit,
                .deinit_fn = Context.on_deinit,
            };

            context.submitted = .{};
            context.shutdown = Atomic(bool).init(false);
            context.pending = .{ .name = null };

            log.debug("{}: init: initializing signal", .{context.client_id});
            try context.signal.init(&context.io, Context.on_signal);
            errdefer context.signal.deinit();

            log.debug("{}: init: spawning thread", .{context.client_id});
            context.thread = std.Thread.spawn(.{}, Context.run, .{context}) catch |err| {
                log.err("{}: failed to spawn thread: {s}", .{
                    context.client_id,
                    @errorName(err),
                });
                return switch (err) {
                    error.Unexpected => error.Unexpected,
                    error.OutOfMemory => error.OutOfMemory,
                    error.SystemResources,
                    error.ThreadQuotaExceeded,
                    error.LockedMemoryLimitExceeded,
                    => error.SystemResources,
                };
            };

            context.registered = false;
            context.client.register(client_register_callback, @intFromPtr(context));

            return context;
        }

        pub fn deinit(self: *Context) void {
            const is_shutdown = self.shutdown.swap(true, .Monotonic);
            if (!is_shutdown) {
                self.thread.join();
                self.signal.deinit();

                self.client.deinit(self.allocator);
                self.message_pool.deinit(self.allocator);
                self.io.deinit();

                self.allocator.free(self.addresses);
                self.allocator.free(self.packets);
                self.allocator.destroy(self);
            }
        }

        fn client_register_callback(user_data: u128, result: *const vsr.RegisterResult) void {
            const self: *Context = @ptrFromInt(@as(usize, @intCast(user_data)));
            _ = result;
            self.registered = true;
            // Some requests may have queued up while the client was registering.
            self.signal.notify();
        }

        pub fn tick(self: *Context) void {
            self.client.tick();
        }

        pub fn run(self: *Context) void {
            var drained_packets: u32 = 0;

            while (true) {
                // Keep running until shutdown:
                const is_shutdown = self.shutdown.load(.Acquire);
                if (is_shutdown) {
                    // We need to drain all free packets, to ensure that all
                    // inflight requests have finished.
                    while (self.packets_free.pop() != null) {
                        drained_packets += 1;
                        if (drained_packets == self.packets.len) return;
                    }
                }

                self.tick();
                self.io.run_for_ns(constants.tick_ms * std.time.ns_per_ms) catch |err| {
                    log.err("{}: IO.run() failed: {s}", .{
                        self.client_id,
                        @errorName(err),
                    });
                    @panic("IO.run() failed");
                };
            }
        }

        fn on_signal(signal: *Signal) void {
            const self = @fieldParentPtr(Context, "signal", signal);

            // Don't send any requests until registration completes.
            if (!self.registered) {
                assert(self.client.request_inflight != null);
                assert(self.client.request_inflight.?.message.header.operation == .register);
                return;
            }

            while (self.submitted.pop()) |packet| {
                self.request(packet);
            }
        }

        fn request(self: *Context, packet: *Packet) void {
            assert(self.registered);

            // Get the size of each request structure in the packet.data:
            const event_size: usize = operation_event_size(packet.operation) orelse {
                return self.on_complete(packet, error.InvalidOperation);
            };

            // Make sure the packet.data size is correct:
            const events = @as([*]const u8, @ptrCast(packet.data))[0..packet.data_size];
            if (events.len == 0 or events.len % event_size != 0) {
                return self.on_complete(packet, error.InvalidDataSize);
            }

            // Make sure the packet.data wouldn't overflow a message:
            if (events.len > constants.message_body_size_max) {
                return self.on_complete(packet, error.TooMuchData);
            }

            packet.batch_next = null;
            packet.batch_tail = packet;
            packet.batch_size = packet.data_size;

            // Nothing inflight means the packet should be submitted right now.
            if (self.client.request_inflight == null) {
                return self.submit(packet);
            }

            // Otherwise, try to batch the packet with another already in self.pending.
            if (StateMachine.batch_logical_allowed.get(@enumFromInt(packet.operation))) {
                var it = self.pending.peek();
                while (it) |root| {
                    it = root.next;

                    // Check for pending packets of the same operation which can be batched.
                    if (root.operation != packet.operation) continue;
                    if (root.batch_size + packet.data_size > constants.message_body_size_max) continue;

                    root.batch_size += packet.data_size;
                    root.batch_tail.?.batch_next = packet;
                    root.batch_tail = packet;
                    return;
                }
            }

            // Couldn't batch with existing packet so push to pending directly.
            packet.next = null;
            self.pending.push(packet);
        }

        fn submit(self: *Context, packet: *Packet) void {
            assert(self.client.request_inflight == null);
            const message = self.client.get_message().build(.request);
            errdefer self.client.release_message(message.base());

            const operation: StateMachine.Operation = @enumFromInt(packet.operation);
            message.header.* = .{
                .release = self.client.release,
                .client = self.client.id,
                .request = 0, // Set by client.raw_request.
                .cluster = self.client.cluster,
                .command = .request,
                .operation = vsr.Operation.from(StateMachine, operation),
                .size = @sizeOf(vsr.Header) + packet.batch_size,
            };

            // Copy all batched packet event data into the message.
            var offset: u32 = 0;
            var it: ?*Packet = packet;
            while (it) |batched| {
                it = batched.batch_next;

                const event_data = @as([*]const u8, @ptrCast(batched.data.?))[0..batched.data_size];
                stdx.copy_disjoint(.inexact, u8, message.body()[offset..], event_data);
                offset += @intCast(event_data.len);
            }

            assert(offset == packet.batch_size);
            self.client.raw_request(
                Context.on_result,
                @bitCast(UserData{
                    .self = self,
                    .packet = packet,
                }),
                message,
            );
        }

        fn on_result(
            raw_user_data: u128,
            op: StateMachine.Operation,
            reply: []u8,
        ) void {
            const user_data: UserData = @bitCast(raw_user_data);
            const self = user_data.self;
            const packet = user_data.packet;

            // Submit the next pending packet now that VSR has completed this one.
            if (self.pending.pop()) |packet_next| {
                self.submit(packet_next);
            }

            switch (op) {
                inline else => |operation| {
                    // on_result should never be called with an operation not green-lit by request()
                    // This also guards from passing an unsupported operation into DemuxerType.
                    if (comptime operation_event_size(@intFromEnum(operation)) == null) {
                        unreachable;
                    }

                    // Demuxer expects []u8 but VSR callback provides []const u8.
                    // The bytes are known to come from a Message body that will be soon discarded
                    // therefor it's safe to @constCast and potentially modify the data in-place.
                    var demuxer = Client.DemuxerType(operation).init(@constCast(reply));

                    var it: ?*Packet = packet;
                    var event_offset: u32 = 0;
                    while (it) |batched| {
                        it = batched.batch_next;

                        const event_count = @divExact(batched.data_size, @sizeOf(StateMachine.Event(operation)));
                        const results = demuxer.decode(event_offset, event_count);
                        event_offset += event_count;

                        if (!StateMachine.batch_logical_allowed.get(operation)) {
                            assert(results.len == reply.len);
                        }

                        assert(batched.operation == @intFromEnum(operation));
                        self.on_complete(batched, results);
                    }
                },
            }
        }

        fn on_complete(
            self: *Context,
            packet: *Packet,
            result: PacketError![]const u8,
        ) void {
            const completion_ctx = self.implementation.completion_ctx;
            const tb_client = api.context_to_client(&self.implementation);
            const bytes = result catch |err| {
                packet.status = switch (err) {
                    error.TooMuchData => .too_much_data,
                    error.InvalidOperation => .invalid_operation,
                    error.InvalidDataSize => .invalid_data_size,
                };
                return (self.completion_fn)(completion_ctx, tb_client, packet, null, 0);
            };

            // The packet completed normally.
            packet.status = .ok;
            (self.completion_fn)(completion_ctx, tb_client, packet, bytes.ptr, @intCast(bytes.len));
        }

        inline fn get_context(implementation: *ContextImplementation) *Context {
            return @fieldParentPtr(Context, "implementation", implementation);
        }

        fn on_acquire_packet(implementation: *ContextImplementation, out_packet: *?*Packet) PacketAcquireStatus {
            const self = get_context(implementation);

            // During shutdown, no packet can be acquired by the application.
            const is_shutdown = self.shutdown.load(.Acquire);
            if (is_shutdown) {
                return .shutdown;
            } else if (self.packets_free.pop()) |packet| {
                out_packet.* = packet;
                return .ok;
            } else {
                return .concurrency_max_exceeded;
            }
        }

        fn on_release_packet(implementation: *ContextImplementation, packet: *Packet) void {
            const self = get_context(implementation);
            return self.packets_free.push(packet);
        }

        fn on_submit(implementation: *ContextImplementation, packet: *Packet) void {
            const self = get_context(implementation);
            self.submitted.push(packet);
            self.signal.notify();
        }

        fn on_deinit(implementation: *ContextImplementation) void {
            const self = get_context(implementation);
            self.deinit();
        }
    };
}
