const std = @import("std");
const Allocator = std.mem.Allocator;
const Session = @import("Session.zig");

// --- Constants ---

/// Maximum concurrent sessions.
const pool_size: u8 = 16;

// --- Public types ---

pub const PoolError = error{
    PoolFull,
    SessionNotFound,
    CreateFailed,
};

// --- SessionPool type ---

sessions: [pool_size]?Session,
count: u8,
last_activity: [pool_size]i64,
alloc: Allocator,

const SessionPool = @This();

// --- Step 3.3.1: init ---

/// Heap-allocate a SessionPool. Each Session contains a 65KB read_buf,
/// so 16 sessions = ~1MB — too large for stack allocation.
///
/// Postconditions:
/// - count == 0
/// - all slots are null
pub fn init(alloc: Allocator) !*SessionPool {
    const pool = try alloc.create(SessionPool);
    pool.* = .{
        .sessions = [_]?Session{null} ** pool_size,
        .count = 0,
        .last_activity = [_]i64{0} ** pool_size,
        .alloc = alloc,
    };

    // Postconditions.
    std.debug.assert(pool.count == 0);
    for (pool.sessions) |s| {
        std.debug.assert(s == null);
    }

    return pool;
}

/// Free the pool itself. All sessions must be destroyed first.
///
/// Assertion:
/// - count == 0 (no active sessions)
pub fn deinit(self: *SessionPool) void {
    std.debug.assert(self.count == 0);
    self.alloc.destroy(self);
}

// --- create ---

/// Create a new session in the first available slot.
///
/// Assertions:
/// - count < 16 (pool not full)
/// - opts.argv.len > 0
/// Postcondition:
/// - count incremented by 1
pub fn create(self: *SessionPool, opts: Session.CreateOpts) PoolError!u8 {
    std.debug.assert(self.count < pool_size);
    std.debug.assert(opts.argv.len > 0);

    const count_before = self.count;

    // Find first null slot.
    var slot: u8 = 0;
    while (slot < pool_size) : (slot += 1) {
        if (self.sessions[slot] == null) break;
    }

    if (slot >= pool_size) return error.PoolFull;

    self.sessions[slot] = Session.create(
        self.alloc,
        slot,
        opts,
    ) catch return error.CreateFailed;

    // Init stream AFTER the session is at its final heap location in the pool.
    // The ReadonlyStream holds a self-referential pointer to terminal.inner;
    // calling initStream before the struct is placed here would create a
    // dangling pointer when Session.create returns by value.
    self.sessions[slot].?.terminal.initStream();

    self.last_activity[slot] = std.time.milliTimestamp();
    self.count += 1;

    // Postcondition.
    std.debug.assert(self.count == count_before + 1);

    return slot;
}

// --- get ---

/// Get a session by ID.
///
/// Assertions:
/// - id < 16
pub fn get(self: *SessionPool, id: u8) PoolError!*Session {
    std.debug.assert(id < pool_size);

    if (self.sessions[id]) |*sess| {
        self.last_activity[id] = std.time.milliTimestamp();
        return sess;
    }

    return error.SessionNotFound;
}

// --- destroy ---

/// Destroy a session by ID.
///
/// Assertions:
/// - id < 16
/// - slot is not null
/// Postcondition:
/// - count decremented by 1
/// - slot is null
pub fn destroy(self: *SessionPool, id: u8) PoolError!void {
    std.debug.assert(id < pool_size);

    if (self.sessions[id]) |*sess| {
        const count_before = self.count;

        sess.destroy();
        self.sessions[id] = null;
        self.count -= 1;

        // Postconditions.
        std.debug.assert(self.count == count_before - 1);
        std.debug.assert(self.sessions[id] == null);
        return;
    }

    return error.SessionNotFound;
}

// --- destroyAll ---

/// Shutdown all active sessions.
///
/// Postcondition:
/// - count == 0
pub fn destroyAll(self: *SessionPool) void {
    var i: u8 = 0;
    while (i < pool_size) : (i += 1) {
        if (self.sessions[i]) |*sess| {
            sess.destroy();
            self.sessions[i] = null;
            self.count -= 1;
        }
    }

    // Postcondition.
    std.debug.assert(self.count == 0);
}

// ===== Tests =====

test "init and deinit pool" {
    const alloc = std.testing.allocator;

    const pool = try SessionPool.init(alloc);
    try std.testing.expectEqual(@as(u8, 0), pool.count);

    pool.deinit();
}

test "create and destroy session in pool" {
    const alloc = std.testing.allocator;

    const pool = try SessionPool.init(alloc);
    defer pool.deinit();

    const id = try pool.create(.{
        .argv = &[_][]const u8{ "/bin/echo", "test" },
    });

    try std.testing.expectEqual(@as(u8, 1), pool.count);
    try std.testing.expect(id < pool_size);

    // Get the session.
    const sess = try pool.get(id);
    try std.testing.expectEqual(Session.State.active, sess.state);

    try pool.destroy(id);
    try std.testing.expectEqual(@as(u8, 0), pool.count);
}

test "create multiple sessions" {
    const alloc = std.testing.allocator;

    const pool = try SessionPool.init(alloc);
    defer {
        pool.destroyAll();
        pool.deinit();
    }

    const id1 = try pool.create(.{
        .argv = &[_][]const u8{ "/bin/echo", "one" },
    });
    const id2 = try pool.create(.{
        .argv = &[_][]const u8{ "/bin/echo", "two" },
    });
    const id3 = try pool.create(.{
        .argv = &[_][]const u8{ "/bin/echo", "three" },
    });

    try std.testing.expectEqual(@as(u8, 3), pool.count);
    try std.testing.expect(id1 != id2);
    try std.testing.expect(id2 != id3);

    // Destroy one, verify count.
    try pool.destroy(id2);
    try std.testing.expectEqual(@as(u8, 2), pool.count);

    // Get remaining sessions.
    _ = try pool.get(id1);
    _ = try pool.get(id3);

    // id2 should be gone.
    const result = pool.get(id2);
    try std.testing.expectError(PoolError.SessionNotFound, result);
}

test "destroyAll cleans up everything" {
    const alloc = std.testing.allocator;

    const pool = try SessionPool.init(alloc);
    defer pool.deinit();

    _ = try pool.create(.{
        .argv = &[_][]const u8{ "/bin/sleep", "100" },
    });
    _ = try pool.create(.{
        .argv = &[_][]const u8{ "/bin/sleep", "100" },
    });

    try std.testing.expectEqual(@as(u8, 2), pool.count);

    pool.destroyAll();
    try std.testing.expectEqual(@as(u8, 0), pool.count);
}
