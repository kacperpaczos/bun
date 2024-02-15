const bun = @import("root").bun;
const std = @import("std");
const Async = bun.Async;
const JSC = bun.JSC;

pub const WriteResult = union(enum) {
    done: usize,
    wrote: usize,
    pending: usize,
    err: bun.sys.Error,
};

pub fn PosixPipeWriter(
    comptime This: type,
    // Originally this was the comptime vtable struct like the below
    // But that caused a Zig compiler segfault as of 0.12.0-dev.1604+caae40c21
    comptime getFd: fn (*This) bun.FileDescriptor,
    comptime getBuffer: fn (*This) []const u8,
    comptime onWrite: fn (*This, written: usize, done: bool) void,
    comptime registerPoll: ?fn (*This) void,
    comptime onError: fn (*This, bun.sys.Error) void,
    comptime onWritable: fn (*This) void,
) type {
    _ = onWritable; // autofix
    return struct {
        pub fn _tryWrite(this: *This, buf_: []const u8) WriteResult {
            const fd = getFd(this);
            var buf = buf_;

            while (buf.len > 0) {
                switch (writeNonBlocking(fd, buf)) {
                    .err => |err| {
                        if (err.isRetry()) {
                            return .{ .pending = buf_.len - buf.len };
                        }

                        return .{ .err = err };
                    },

                    .result => |wrote| {
                        if (wrote == 0) {
                            return .{ .done = buf_.len - buf.len };
                        }

                        buf = buf[wrote..];
                    },
                }
            }

            return .{ .wrote = buf_.len - buf.len };
        }

        fn writeNonBlocking(fd: bun.FileDescriptor, buf: []const u8) JSC.Maybe(usize) {
            if (comptime bun.Environment.isLinux) {
                if (bun.C.linux.RWFFlagSupport.isMaybeSupported()) {
                    return bun.sys.writeNonblocking(fd, buf);
                }
            }

            switch (bun.isWritable(fd)) {
                .ready, .hup => return bun.sys.write(fd, buf),
                .not_ready => return JSC.Maybe(usize){ .err = bun.sys.Error.retry },
            }
        }

        pub fn onPoll(parent: *This, size_hint: isize, received_hup: bool) void {
            const buffer = getBuffer(parent);

            if (buffer.len == 0 and !received_hup) {
                onWrite(parent, 0, false);
                return;
            }

            switch (drainBufferedData(
                parent,
                buffer,
                if (size_hint > 0) @intCast(size_hint) else std.math.maxInt(usize),
                received_hup,
            )) {
                .pending => |wrote| {
                    if (comptime registerPoll) |register| {
                        register(parent);
                    }
                    if (wrote > 0)
                        onWrite(parent, wrote, false);
                },
                .wrote => |amt| {
                    onWrite(parent, amt, false);
                    if (getBuffer(parent).len > 0) {
                        if (comptime registerPoll) |register| {
                            register(parent);
                        }
                    }
                },
                .err => |err| {
                    onError(parent, err);
                },
                .done => |amt| {
                    onWrite(parent, amt, true);
                },
            }
        }

        pub fn drainBufferedData(parent: *This, input_buffer: []const u8, max_write_size: usize, received_hup: bool) WriteResult {
            _ = received_hup; // autofix
            var buf = input_buffer;
            buf = if (max_write_size < buf.len and max_write_size > 0) buf[0..max_write_size] else buf;
            const original_buf = buf;

            while (buf.len > 0) {
                const attempt = _tryWrite(parent, buf);
                switch (attempt) {
                    .pending => |pending| {
                        return .{ .pending = pending + (original_buf.len - buf.len) };
                    },
                    .wrote => |amt| {
                        buf = buf[amt..];
                    },
                    .err => |err| {
                        const wrote = original_buf.len - buf.len;
                        if (err.isRetry()) {
                            return .{ .pending = wrote };
                        }

                        if (wrote > 0) {
                            onError(parent, err);
                            return .{ .wrote = wrote };
                        } else {
                            return .{ .err = err };
                        }
                    },
                    .done => |amt| {
                        buf = buf[amt..];
                        const wrote = original_buf.len - buf.len;

                        return .{ .done = wrote };
                    },
                }
            }

            const wrote = original_buf.len - buf.len;
            return .{ .wrote = wrote };
        }
    };
}

const PollOrFd = @import("./pipes.zig").PollOrFd;

pub fn PosixBufferedWriter(
    comptime Parent: type,
    comptime onWrite: *const fn (*Parent, amount: usize, done: bool) void,
    comptime onError: *const fn (*Parent, bun.sys.Error) void,
    comptime onClose: ?*const fn (*Parent) void,
    comptime getBuffer: *const fn (*Parent) []const u8,
    comptime onWritable: ?*const fn (*Parent) void,
) type {
    return struct {
        handle: PollOrFd = .{ .closed = {} },
        parent: *Parent = undefined,
        is_done: bool = false,
        pollable: bool = false,
        closed_without_reporting: bool = false,

        const PosixWriter = @This();

        pub fn getPoll(this: *const @This()) ?*Async.FilePoll {
            return this.handle.getPoll();
        }

        pub fn getFd(this: *const PosixWriter) bun.FileDescriptor {
            return this.handle.getFd();
        }

        fn _onError(
            this: *PosixWriter,
            err: bun.sys.Error,
        ) void {
            std.debug.assert(!err.isRetry());

            onError(this.parent, err);

            this.close();
        }

        fn _onWrite(
            this: *PosixWriter,
            written: usize,
            done: bool,
        ) void {
            const was_done = this.is_done == true;
            const parent = this.parent;

            if (done and !was_done) {
                this.closeWithoutReporting();
            }

            onWrite(parent, written, done);
            if (done and !was_done) {
                this.close();
            }
        }

        fn _onWritable(this: *PosixWriter) void {
            if (this.is_done) {
                return;
            }

            if (onWritable) |cb| {
                cb(this.parent);
            }
        }

        fn registerPoll(this: *PosixWriter) void {
            var poll = this.getPoll() orelse return;
            switch (poll.registerWithFd(bun.uws.Loop.get(), .writable, .dispatch, poll.fd)) {
                .err => |err| {
                    onError(this.parent, err);
                },
                .result => {},
            }
        }

        pub const tryWrite = @This()._tryWrite;

        pub fn hasRef(this: *PosixWriter) bool {
            if (this.is_done) {
                return false;
            }

            const poll = this.getPoll() orelse return false;
            return poll.canEnableKeepingProcessAlive();
        }

        pub fn enableKeepingProcessAlive(this: *PosixWriter, event_loop: anytype) void {
            this.updateRef(event_loop, true);
        }

        pub fn disableKeepingProcessAlive(this: *PosixWriter, event_loop: anytype) void {
            this.updateRef(event_loop, false);
        }

        fn getBufferInternal(this: *PosixWriter) []const u8 {
            return getBuffer(this.parent);
        }

        pub usingnamespace PosixPipeWriter(@This(), getFd, getBufferInternal, _onWrite, registerPoll, _onError, _onWritable);

        pub fn end(this: *PosixWriter) void {
            if (this.is_done) {
                return;
            }

            this.is_done = true;
            this.close();
        }

        fn closeWithoutReporting(this: *PosixWriter) void {
            if (this.getFd() != bun.invalid_fd) {
                std.debug.assert(!this.closed_without_reporting);
                this.closed_without_reporting = true;
                this.handle.close(null, {});
            }
        }

        pub fn close(this: *PosixWriter) void {
            if (onClose) |closer| {
                if (this.closed_without_reporting) {
                    this.closed_without_reporting = false;
                    closer(this.parent);
                } else {
                    this.handle.close(this.parent, closer);
                }
            }
        }

        pub fn updateRef(this: *const PosixWriter, event_loop: anytype, value: bool) void {
            const poll = this.getPoll() orelse return;
            poll.setKeepingProcessAlive(event_loop, value);
        }

        pub fn setParent(this: *PosixWriter, parent: *Parent) void {
            this.parent = parent;
            this.handle.setOwner(this);
        }

        pub fn write(this: *PosixWriter) void {
            this.onPoll(0, false);
        }

        pub fn watch(this: *PosixWriter) void {
            if (this.pollable) {
                if (this.handle == .fd) {
                    this.handle = .{ .poll = Async.FilePoll.init(@as(*Parent, @ptrCast(this.parent)).eventLoop(), this.getFd(), .{}, PosixWriter, this) };
                }

                this.registerPoll();
            }
        }

        pub fn start(this: *PosixWriter, fd: bun.FileDescriptor, pollable: bool) JSC.Maybe(void) {
            this.pollable = pollable;
            if (!pollable) {
                std.debug.assert(this.handle != .poll);
                this.handle = .{ .fd = fd };
                return JSC.Maybe(void){ .result = {} };
            }
            var poll = this.getPoll() orelse brk: {
                this.handle = .{ .poll = Async.FilePoll.init(@as(*Parent, @ptrCast(this.parent)).eventLoop(), fd, .{}, PosixWriter, this) };
                break :brk this.handle.poll;
            };
            const loop = @as(*Parent, @ptrCast(this.parent)).eventLoop().loop();

            switch (poll.registerWithFd(loop, .writable, .dispatch, fd)) {
                .err => |err| {
                    return JSC.Maybe(void){ .err = err };
                },
                .result => {
                    this.enableKeepingProcessAlive(@as(*Parent, @ptrCast(this.parent)).eventLoop());
                },
            }

            return JSC.Maybe(void){ .result = {} };
        }
    };
}

pub fn PosixStreamingWriter(
    comptime Parent: type,
    comptime onWrite: fn (*Parent, amount: usize, done: bool) void,
    comptime onError: fn (*Parent, bun.sys.Error) void,
    comptime onReady: ?fn (*Parent) void,
    comptime onClose: fn (*Parent) void,
) type {
    return struct {
        buffer: std.ArrayList(u8) = std.ArrayList(u8).init(bun.default_allocator),
        handle: PollOrFd = .{ .closed = {} },
        parent: *Parent = undefined,
        head: usize = 0,
        is_done: bool = false,
        closed_without_reporting: bool = false,

        // TODO:
        chunk_size: usize = 0,

        pub fn getPoll(this: *@This()) ?*Async.FilePoll {
            return this.handle.getPoll();
        }

        pub fn getFd(this: *PosixWriter) bun.FileDescriptor {
            return this.handle.getFd();
        }

        const PosixWriter = @This();

        pub fn getBuffer(this: *PosixWriter) []const u8 {
            return this.buffer.items[this.head..];
        }

        fn _onError(
            this: *PosixWriter,
            err: bun.sys.Error,
        ) void {
            std.debug.assert(!err.isRetry());

            this.closeWithoutReporting();
            this.is_done = true;

            onError(@alignCast(@ptrCast(this.parent)), err);
            this.close();
        }

        fn _onWrite(
            this: *PosixWriter,
            written: usize,
            done: bool,
        ) void {
            this.head += written;

            if (done) {
                this.closeWithoutReporting();
            }

            if (this.buffer.items.len == this.head) {
                if (this.buffer.capacity > 1024 * 1024 and !done) {
                    this.buffer.clearAndFree();
                } else {
                    this.buffer.clearRetainingCapacity();
                }
                this.head = 0;
            }

            onWrite(@ptrCast(this.parent), written, done);
        }

        pub fn setParent(this: *PosixWriter, parent: *Parent) void {
            this.parent = parent;
            this.handle.setOwner(this);
        }

        fn _onWritable(this: *PosixWriter) void {
            if (this.is_done or this.closed_without_reporting) {
                return;
            }

            this.head = 0;
            if (onReady) |cb| {
                cb(@ptrCast(this.parent));
            }
        }

        fn closeWithoutReporting(this: *PosixWriter) void {
            if (this.getFd() != bun.invalid_fd) {
                std.debug.assert(!this.closed_without_reporting);
                this.closed_without_reporting = true;
                this.handle.close(null, {});
            }
        }

        fn registerPoll(this: *PosixWriter) void {
            const poll = this.getPoll() orelse return;
            switch (poll.registerWithFd(@as(*Parent, @ptrCast(this.parent)).loop(), .writable, .dispatch, poll.fd)) {
                .err => |err| {
                    onError(this.parent, err);
                    this.close();
                },
                .result => {},
            }
        }

        pub fn tryWrite(this: *PosixWriter, buf: []const u8) WriteResult {
            if (this.is_done or this.closed_without_reporting) {
                return .{ .done = 0 };
            }

            if (this.buffer.items.len > 0) {
                this.buffer.appendSlice(buf) catch {
                    return .{ .err = bun.sys.Error.oom };
                };

                return .{ .pending = 0 };
            }

            return @This()._tryWrite(this, buf);
        }

        pub fn writeUTF16(this: *PosixWriter, buf: []const u16) WriteResult {
            if (this.is_done or this.closed_without_reporting) {
                return .{ .done = 0 };
            }

            const had_buffered_data = this.buffer.items.len > 0;
            {
                var byte_list = bun.ByteList.fromList(this.buffer);
                defer this.buffer = byte_list.listManaged(bun.default_allocator);

                _ = byte_list.writeUTF16(bun.default_allocator, buf) catch {
                    return .{ .err = bun.sys.Error.oom };
                };
            }

            if (had_buffered_data) {
                return .{ .pending = 0 };
            }

            return this._tryWriteNewlyBufferedData();
        }

        pub fn writeLatin1(this: *PosixWriter, buf: []const u8) WriteResult {
            if (this.is_done or this.closed_without_reporting) {
                return .{ .done = 0 };
            }

            if (bun.strings.isAllASCII(buf)) {
                return this.write(buf);
            }

            const had_buffered_data = this.buffer.items.len > 0;
            {
                var byte_list = bun.ByteList.fromList(this.buffer);
                defer this.buffer = byte_list.listManaged(bun.default_allocator);

                _ = byte_list.writeLatin1(bun.default_allocator, buf) catch {
                    return .{ .err = bun.sys.Error.oom };
                };
            }

            if (had_buffered_data) {
                return .{ .pending = 0 };
            }

            return this._tryWriteNewlyBufferedData();
        }

        fn _tryWriteNewlyBufferedData(this: *PosixWriter) WriteResult {
            std.debug.assert(!this.is_done);

            switch (@This()._tryWrite(this, this.buffer.items)) {
                .wrote => |amt| {
                    if (amt == this.buffer.items.len) {
                        this.buffer.clearRetainingCapacity();
                    } else {
                        this.head = amt;
                    }
                    return .{ .wrote = amt };
                },
                .done => |amt| {
                    this.buffer.clearRetainingCapacity();

                    return .{ .done = amt };
                },
                else => |r| return r,
            }
        }

        pub fn write(this: *PosixWriter, buf: []const u8) WriteResult {
            if (this.is_done or this.closed_without_reporting) {
                return .{ .done = 0 };
            }

            if (this.buffer.items.len + buf.len < this.chunk_size) {
                this.buffer.appendSlice(buf) catch {
                    return .{ .err = bun.sys.Error.oom };
                };

                return .{ .pending = 0 };
            }

            const rc = @This()._tryWrite(this, buf);
            this.head = 0;
            switch (rc) {
                .pending => |pending| {
                    registerPoll(this);

                    this.buffer.appendSlice(buf[pending..]) catch {
                        return .{ .err = bun.sys.Error.oom };
                    };
                },
                .wrote => |amt| {
                    if (amt < buf.len) {
                        this.buffer.appendSlice(buf[amt..]) catch {
                            return .{ .err = bun.sys.Error.oom };
                        };
                    } else {
                        this.buffer.clearRetainingCapacity();
                    }
                },
                .done => |amt| {
                    return .{ .done = amt };
                },
                else => {},
            }

            return rc;
        }

        pub usingnamespace PosixPipeWriter(@This(), getFd, getBuffer, _onWrite, registerPoll, _onError, _onWritable);

        pub fn flush(this: *PosixWriter) WriteResult {
            if (this.closed_without_reporting or this.is_done) {
                return .{ .done = 0 };
            }

            const buffer = this.buffer.items;
            if (buffer.len == 0) {
                return .{ .wrote = 0 };
            }

            return this.drainBufferedData(buffer, std.math.maxInt(usize), brk: {
                if (this.getPoll()) |poll| {
                    break :brk poll.flags.contains(.hup);
                }

                break :brk false;
            });
        }

        pub fn deinit(this: *PosixWriter) void {
            this.buffer.clearAndFree();
            this.close();
        }

        pub fn hasRef(this: *PosixWriter) bool {
            const poll = this.getPoll() orelse return false;
            return !this.is_done and poll.canEnableKeepingProcessAlive();
        }

        pub fn enableKeepingProcessAlive(this: *PosixWriter, event_loop: JSC.EventLoopHandle) void {
            if (this.is_done) return;
            const poll = this.getPoll() orelse return;

            poll.enableKeepingProcessAlive(event_loop);
        }

        pub fn disableKeepingProcessAlive(this: *PosixWriter, event_loop: JSC.EventLoopHandle) void {
            const poll = this.getPoll() orelse return;
            poll.disableKeepingProcessAlive(event_loop);
        }

        pub fn updateRef(this: *PosixWriter, event_loop: JSC.EventLoopHandle, value: bool) void {
            if (value) {
                this.enableKeepingProcessAlive(event_loop);
            } else {
                this.disableKeepingProcessAlive(event_loop);
            }
        }

        pub fn end(this: *PosixWriter) void {
            if (this.is_done) {
                return;
            }

            this.is_done = true;
            this.close();
        }

        pub fn close(this: *PosixWriter) void {
            if (this.closed_without_reporting) {
                this.closed_without_reporting = false;
                std.debug.assert(this.getFd() == bun.invalid_fd);
                onClose(@ptrCast(this.parent));
                return;
            }

            this.handle.close(@ptrCast(this.parent), onClose);
        }

        pub fn start(this: *PosixWriter, fd: bun.FileDescriptor, is_pollable: bool) JSC.Maybe(void) {
            if (!is_pollable) {
                this.close();
                this.handle = .{ .fd = fd };
                return JSC.Maybe(void){ .result = {} };
            }

            const loop = @as(*Parent, @ptrCast(this.parent)).eventLoop();
            var poll = this.getPoll() orelse brk: {
                this.handle = .{ .poll = Async.FilePoll.init(loop, fd, .{}, PosixWriter, this) };
                break :brk this.handle.poll;
            };

            switch (poll.registerWithFd(loop.loop(), .writable, .dispatch, fd)) {
                .err => |err| {
                    return JSC.Maybe(void){ .err = err };
                },
                .result => {},
            }

            return JSC.Maybe(void){ .result = {} };
        }
    };
}
const uv = bun.windows.libuv;

/// Will provide base behavior for pipe writers
/// The WindowsPipeWriter type should implement the following interface:
/// struct {
///   pipe: ?*uv.Pipe = undefined,
///   parent: *Parent = undefined,
///   is_done: bool = false,
///   pub fn startWithCurrentPipe(this: *WindowsPipeWriter) bun.JSC.Maybe(void),
///   fn onClosePipe(pipe: *uv.Pipe) callconv(.C) void,
/// };
fn BaseWindowsPipeWriter(
    comptime WindowsPipeWriter: type,
    comptime Parent: type,
) type {
    return struct {
        pub fn getFd(this: *const WindowsPipeWriter) bun.FileDescriptor {
            const pipe = this.pipe orelse return bun.invalid_fd;
            return pipe.fd();
        }

        pub fn hasRef(this: *const WindowsPipeWriter) bool {
            if (this.is_done) {
                return false;
            }
            if (this.pipe) |pipe| return pipe.hasRef();
            return false;
        }

        pub fn enableKeepingProcessAlive(this: *WindowsPipeWriter, event_loop: anytype) void {
            this.updateRef(event_loop, true);
        }

        pub fn disableKeepingProcessAlive(this: *WindowsPipeWriter, event_loop: anytype) void {
            this.updateRef(event_loop, false);
        }

        pub fn close(this: *WindowsPipeWriter) void {
            this.is_done = true;
            if (this.pipe) |pipe| {
                pipe.close(&WindowsPipeWriter.onClosePipe);
            }
        }

        pub fn updateRef(this: *WindowsPipeWriter, _: anytype, value: bool) void {
            if (this.pipe) |pipe| {
                if (value) {
                    pipe.ref();
                } else {
                    pipe.unref();
                }
            }
        }

        pub fn setParent(this: *WindowsPipeWriter, parent: *Parent) void {
            this.parent = parent;
            if (!this.is_done) {
                if (this.pipe) |pipe| {
                    pipe.data = this;
                }
            }
        }

        pub fn watch(_: *WindowsPipeWriter) void {
            // no-op
        }

        pub fn startWithPipe(this: *WindowsPipeWriter, pipe: *uv.Pipe) bun.JSC.Maybe(void) {
            std.debug.assert(this.pipe == null);
            this.pipe = pipe;
            return this.startWithCurrentPipe();
        }

        pub fn open(this: *WindowsPipeWriter, loop: *uv.Loop, fd: bun.FileDescriptor, ipc: bool) bun.JSC.Maybe(void) {
            const pipe = this.pipe orelse return .{ .err = bun.sys.Error.fromCode(bun.C.E.PIPE, .pipe) };
            switch (pipe.init(loop, ipc)) {
                .err => |err| {
                    return .{ .err = err };
                },
                else => {},
            }

            pipe.data = this;

            switch (pipe.open(bun.uvfdcast(fd))) {
                .err => |err| {
                    return .{ .err = err };
                },
                else => {},
            }

            return .{ .result = {} };
        }

        pub fn start(this: *WindowsPipeWriter, fd: bun.FileDescriptor, _: bool) bun.JSC.Maybe(void) {
            //TODO: check detect if its a tty here and use uv_tty_t instead of pipe
            std.debug.assert(this.pipe == null);
            this.pipe = bun.default_allocator.create(uv.Pipe) catch bun.outOfMemory();
            if (this.open(uv.Loop.get(), fd, false).asErr()) |err| return .{ .err = err };
            return this.startWithCurrentPipe();
        }
    };
}

pub fn WindowsBufferedWriter(
    comptime Parent: type,
    comptime onWrite: *const fn (*Parent, amount: usize, done: bool) void,
    comptime onError: *const fn (*Parent, bun.sys.Error) void,
    comptime onClose: ?*const fn (*Parent) void,
    comptime getBuffer: *const fn (*Parent) []const u8,
    comptime onWritable: ?*const fn (*Parent) void,
) type {
    return struct {
        pipe: ?*uv.Pipe = undefined,
        parent: *Parent = undefined,
        is_done: bool = false,
        // we use only one write_req, any queued data in outgoing will be flushed after this ends
        write_req: uv.uv_write_t = std.mem.zeroes(uv.uv_write_t),

        pending_payload_size: usize = 0,

        const WindowsWriter = @This();

        pub usingnamespace BaseWindowsPipeWriter(WindowsWriter, Parent);

        fn onClosePipe(pipe: *uv.Pipe) callconv(.C) void {
            const this = bun.cast(*WindowsWriter, pipe.data);
            if (onClose) |onCloseFn| {
                onCloseFn(this.parent);
            }
        }

        pub fn startWithCurrentPipe(this: *WindowsWriter) bun.JSC.Maybe(void) {
            std.debug.assert(this.pipe != null);
            this.is_done = false;
            this.write();
            return .{ .result = {} };
        }

        fn onWriteComplete(this: *WindowsWriter, status: uv.ReturnCode) void {
            const written = this.pending_payload_size;
            this.pending_payload_size = 0;
            if (status.toError(.write)) |err| {
                this.close();
                onError(this.parent, err);
                return;
            }
            if (status.toError(.write)) |err| {
                this.close();
                onError(this.parent, err);
                return;
            }
            const pending = this.getBufferInternal();
            const has_pending_data = (pending.len - written) == 0;
            onWrite(this.parent, @intCast(written), this.is_done and has_pending_data);
            if (this.is_done and !has_pending_data) {
                // already done and end was called
                this.close();
                return;
            }

            if (onWritable) |onWritableFn| {
                onWritableFn(this.parent);
            }
        }

        pub fn write(this: *WindowsWriter) void {
            const buffer = this.getBufferInternal();
            // if we are already done or if we have some pending payload we just wait until next write
            if (this.is_done or this.pending_payload_size > 0 or buffer.len == 0) {
                return;
            }

            const pipe = this.pipe orelse return;
            var to_write = buffer;
            while (to_write.len > 0) {
                switch (pipe.tryWrite(to_write)) {
                    .err => |err| {
                        if (err.isRetry()) {
                            // the buffered version should always have a stable ptr
                            this.pending_payload_size = to_write.len;
                            if (this.write_req.write(@ptrCast(pipe), to_write, this, onWriteComplete).asErr()) |write_err| {
                                this.close();
                                onError(this.parent, write_err);
                                return;
                            }
                            const written = buffer.len - to_write.len;
                            if (written > 0) {
                                onWrite(this.parent, written, false);
                            }
                            return;
                        }
                        this.close();
                        onError(this.parent, err);
                        return;
                    },
                    .result => |bytes_written| {
                        to_write = to_write[bytes_written..];
                    },
                }
            }

            const written = buffer.len - to_write.len;
            const done = to_write.len == 0;
            onWrite(this.parent, written, done);
            if (done and this.is_done) {
                this.close();
            }
        }

        fn getBufferInternal(this: *WindowsWriter) []const u8 {
            return getBuffer(this.parent);
        }

        pub fn end(this: *WindowsWriter) void {
            if (this.is_done) {
                return;
            }

            this.is_done = true;
            if (this.pending_payload_size == 0) {
                // will auto close when pending stuff get written
                this.close();
            }
        }
    };
}

/// Basic std.ArrayList(u8) + u32 cursor wrapper
const StreamBuffer = struct {
    list: std.ArrayList(u8) = std.ArrayList(u8).init(bun.default_allocator),
    // should cursor be usize?
    cursor: u32 = 0,

    pub fn reset(this: *StreamBuffer) void {
        this.cursor = 0;
        if (this.list.capacity > 32 * 1024) {
            this.list.shrinkAndFree(std.mem.page_size);
        }
        this.list.clearRetainingCapacity();
    }

    pub fn size(this: *const StreamBuffer) usize {
        return this.list.items.len - this.cursor;
    }

    pub fn isEmpty(this: *const StreamBuffer) bool {
        return this.size() == 0;
    }

    pub fn isNotEmpty(this: *const StreamBuffer) bool {
        return this.size() > 0;
    }

    pub fn write(this: *StreamBuffer, buffer: []const u8) !void {
        _ = try this.list.appendSlice(buffer);
    }

    pub fn writeLatin1(this: *StreamBuffer, buffer: []const u8) !void {
        if (bun.strings.isAllASCII(buffer)) {
            return this.write(buffer);
        }

        var byte_list = bun.ByteList.fromList(this.list);
        defer this.list = byte_list.listManaged(this.list.allocator);

        _ = try byte_list.writeLatin1(this.list.allocator, buffer);
    }

    pub fn writeUTF16(this: *StreamBuffer, buffer: []const u16) !void {
        var byte_list = bun.ByteList.fromList(this.list);
        defer this.list = byte_list.listManaged(this.list.allocator);

        _ = try byte_list.writeUTF16(this.list.allocator, buffer);
    }

    pub fn slice(this: *StreamBuffer) []const u8 {
        return this.list.items[this.cursor..];
    }

    pub fn deinit(this: *StreamBuffer) void {
        this.cursor = 0;
        this.list.clearAndFree();
    }
};

pub fn WindowsStreamingWriter(
    comptime Parent: type,
    /// reports the amount written and done means that we dont have any other pending data to send (but we may send more data)
    comptime onWrite: fn (*Parent, amount: usize, done: bool) void,
    comptime onError: fn (*Parent, bun.sys.Error) void,
    comptime onWritable: ?fn (*Parent) void,
    comptime onClose: fn (*Parent) void,
) type {
    return struct {
        pipe: ?*uv.Pipe = undefined,
        parent: *Parent = undefined,
        is_done: bool = false,
        // we use only one write_req, any queued data in outgoing will be flushed after this ends
        write_req: uv.uv_write_t = std.mem.zeroes(uv.uv_write_t),

        // queue any data that we want to write here
        outgoing: StreamBuffer = .{},
        // libuv requires a stable ptr when doing async so we swap buffers
        current_payload: StreamBuffer = .{},
        // we preserve the last write result for simplicity
        last_write_result: WriteResult = .{ .wrote = 0 },
        // some error happed? we will not report onClose only onError
        closed_without_reporting: bool = false,

        pub usingnamespace BaseWindowsPipeWriter(WindowsWriter, Parent);

        fn onClosePipe(pipe: *uv.Pipe) callconv(.C) void {
            const this = bun.cast(*WindowsWriter, pipe.data);
            this.pipe = null;
            if (!this.closed_without_reporting) {
                onClose(this.parent);
            }
        }

        pub fn startWithCurrentPipe(this: *WindowsWriter) bun.JSC.Maybe(void) {
            std.debug.assert(this.pipe != null);
            this.is_done = false;
            return .{ .result = {} };
        }

        fn hasPendingData(this: *WindowsWriter) bool {
            return (this.outgoing.isNotEmpty() and this.current_payload.isNotEmpty());
        }

        fn isDone(this: *WindowsWriter) bool {
            // done is flags andd no more data queued? so we are done!
            return this.is_done and !this.hasPendingData();
        }

        fn onWriteComplete(this: *WindowsWriter, status: uv.ReturnCode) void {
            if (status.toError(.write)) |err| {
                this.closeWithoutReporting();
                this.last_write_result = .{ .err = err };
                onError(this.parent, err);
                return;
            }
            // success means that we send all the data inside current_payload
            const written = this.current_payload.size();
            this.current_payload.reset();

            // if we dont have more outgoing data we report done in onWrite
            const done = this.outgoing.isEmpty();
            if (this.is_done and done) {
                // we already call .end lets close the connection
                this.last_write_result = .{ .done = written };
                this.close();
                onWrite(this.parent, written, true);
                return;
            }
            // .end was not called yet
            this.last_write_result = .{ .wrote = written };

            // report data written
            onWrite(this.parent, written, done);

            // process pending outgoing data if any
            if (done or this.processSend()) {
                // we are still writable we should report now so more things can be written
                if (onWritable) |onWritableFn| {
                    onWritableFn(this.parent);
                }
            }
        }

        /// this tries to send more data returning if we are writable or not after this
        fn processSend(this: *WindowsWriter) bool {
            if (this.current_payload.isNotEmpty()) {
                // we have some pending async request, the next outgoing data will be processed after this finish
                this.last_write_result = .{ .pending = 0 };
                return false;
            }

            var bytes = this.outgoing.slice();
            // nothing todo (we assume we are writable until we try to write something)
            if (bytes.len == 0) {
                this.last_write_result = .{ .wrote = 0 };
                return true;
            }

            const initial_payload_len = bytes.len;
            var pipe = this.pipe orelse {
                this.closeWithoutReporting();
                const err = bun.sys.Error.fromCode(bun.C.E.PIPE, .pipe);
                this.last_write_result = .{ .err = err };
                onError(this.parent, err);
                return false;
            };
            var writable = true;
            while (true) {
                switch (pipe.tryWrite(bytes)) {
                    .err => |err| {
                        if (!err.isRetry()) {
                            this.closeWithoutReporting();
                            this.last_write_result = .{ .err = err };
                            onError(this.parent, err);
                            return false;
                        }
                        writable = false;

                        // ok we hit EGAIN and need to go async
                        if (this.current_payload.isNotEmpty()) {
                            // we already have a under going queued process
                            // just wait the current request finish to send the next outgoing data
                            break;
                        }

                        // current payload is empty we can just swap with outgoing
                        const temp = this.current_payload;
                        this.current_payload = this.outgoing;
                        this.outgoing = temp;

                        // enqueue the write
                        if (this.write_req.write(@ptrCast(pipe), bytes, this, onWriteComplete).asErr()) |write_err| {
                            this.closeWithoutReporting();
                            this.last_write_result = .{ .err = err };
                            onError(this.parent, write_err);
                            this.close();
                            return false;
                        }
                        break;
                    },
                    .result => |written| {
                        bytes = bytes[0..written];
                        if (bytes.len == 0) {
                            this.outgoing.reset();
                            break;
                        }
                        this.outgoing.cursor += @intCast(written);
                    },
                }
            }
            const written = initial_payload_len - bytes.len;
            if (this.isDone()) {
                // if we are done and have no more data this means we called .end() and needs to close after writting everything
                this.close();
                this.last_write_result = .{ .done = written };
                writable = false;
                onWrite(this.parent, written, true);
            } else {
                const done = !this.hasPendingData();
                // if we queued some data we will report pending otherwise we should report that we wrote
                this.last_write_result = if (done) .{ .wrote = written } else .{ .pending = written };
                if (written > 0) {
                    // we need to keep track of how much we wrote here
                    onWrite(this.parent, written, done);
                }
            }
            return writable;
        }

        const WindowsWriter = @This();

        fn closeWithoutReporting(this: *WindowsWriter) void {
            if (this.getFd() != bun.invalid_fd) {
                std.debug.assert(!this.closed_without_reporting);
                this.closed_without_reporting = true;
                this.close();
            }
        }

        pub fn deinit(this: *WindowsWriter) void {
            // clean both buffers if needed
            this.outgoing.deinit();
            this.current_payload.deinit();
            this.close();
        }

        pub fn writeUTF16(this: *WindowsWriter, buf: []const u16) WriteResult {
            if (this.is_done) {
                return .{ .done = 0 };
            }

            const had_buffered_data = this.outgoing.isNotEmpty();
            this.outgoing.writeUTF16(buf) catch {
                return .{ .err = bun.sys.Error.oom };
            };

            if (had_buffered_data) {
                return .{ .pending = 0 };
            }
            _ = this.processSend();
            return this.last_write_result;
        }

        pub fn writeLatin1(this: *WindowsWriter, buffer: []const u8) WriteResult {
            if (this.is_done) {
                return .{ .done = 0 };
            }

            const had_buffered_data = this.outgoing.isNotEmpty();
            this.outgoing.writeLatin1(buffer) catch {
                return .{ .err = bun.sys.Error.oom };
            };

            if (had_buffered_data) {
                return .{ .pending = 0 };
            }

            _ = this.processSend();
            return this.last_write_result;
        }

        pub fn write(this: *WindowsWriter, buffer: []const u8) WriteResult {
            if (this.is_done) {
                return .{ .done = 0 };
            }

            if (this.outgoing.isNotEmpty()) {
                this.outgoing.write(buffer) catch {
                    return .{ .err = bun.sys.Error.oom };
                };

                return .{ .pending = 0 };
            }

            _ = this.processSend();
            return this.last_write_result;
        }

        pub fn flush(this: *WindowsWriter) WriteResult {
            if (this.is_done) {
                return .{ .done = 0 };
            }
            _ = this.processSend();
            return this.last_write_result;
        }

        pub fn end(this: *WindowsWriter) void {
            if (this.is_done) {
                return;
            }

            this.is_done = true;
            this.closed_without_reporting = false;
            // if we are done we can call close if not we wait all the data to be flushed
            if (this.isDone()) {
                this.close();
            }
        }
    };
}

pub const BufferedWriter = if (bun.Environment.isPosix) PosixBufferedWriter else WindowsBufferedWriter;
pub const StreamingWriter = if (bun.Environment.isPosix) PosixStreamingWriter else WindowsStreamingWriter;