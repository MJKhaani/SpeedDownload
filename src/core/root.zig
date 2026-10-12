//! Portable download job state and transition rules.
//!
//! This module owns no I/O, networking, persistence, or UI concerns. It defines
//! the state vocabulary and validates state changes for the engine and clients.
//! See PROJECT.md sections 4.1 and 5.1.

pub const State = enum {
    queued,
    scheduled,
    resolving,
    connecting,
    downloading,
    paused,
    retry_wait,
    verifying,
    completed,
    failed,
    canceled,
};

/// Snapshot exposed to CLI/UI clients. Protocol workers can update byte counts
/// without leaking their internal I/O objects across the core boundary.
pub const Progress = struct {
    completed_bytes: u64 = 0,
    total_bytes: ?u64 = null,

    pub fn fraction(self: Progress) ?f64 {
        const total = self.total_bytes orelse return null;
        if (total == 0) return if (self.completed_bytes == 0) 1 else null;
        if (self.completed_bytes > total) return null;
        return @as(f64, @floatFromInt(self.completed_bytes)) / @as(f64, @floatFromInt(total));
    }
};

pub const TransitionError = error{InvalidTransition};

/// Reports whether a job may move from `from` to `to`.
///
/// Terminal states do not transition. A canceled job is final; restarting it
/// must create a new job ID so history and partial-file ownership stay clear.
pub fn canTransition(from: State, to: State) bool {
    if (from == to or isTerminal(from)) return false;

    return switch (from) {
        .queued => to == .scheduled or to == .resolving or to == .canceled,
        .scheduled => to == .queued or to == .resolving or to == .canceled,
        .resolving => to == .connecting or to == .retry_wait or to == .paused or to == .failed or to == .canceled,
        .connecting => to == .downloading or to == .retry_wait or to == .paused or to == .failed or to == .canceled,
        .downloading => to == .retry_wait or to == .paused or to == .verifying or to == .failed or to == .canceled,
        .paused => to == .queued or to == .canceled,
        .retry_wait => to == .queued or to == .resolving or to == .failed or to == .canceled,
        .verifying => to == .completed or to == .retry_wait or to == .failed or to == .canceled,
        .completed, .failed, .canceled => false,
    };
}

/// Applies a validated state change or returns `error.InvalidTransition`.
pub fn transition(state: *State, next: State) TransitionError!void {
    if (!canTransition(state.*, next)) return error.InvalidTransition;
    state.* = next;
}

/// Identifies states that cannot be resumed or otherwise changed in place.
pub fn isTerminal(state: State) bool {
    return state == .completed or state == .failed or state == .canceled;
}

test "queued job can start or be scheduled, but not skip protocol phases" {
    try @import("std").testing.expect(canTransition(.queued, .resolving));
    try @import("std").testing.expect(canTransition(.queued, .scheduled));
    try @import("std").testing.expect(!canTransition(.queued, .downloading));
}

test "active transfer can pause, retry, verify, or terminate" {
    try @import("std").testing.expect(canTransition(.downloading, .paused));
    try @import("std").testing.expect(canTransition(.downloading, .retry_wait));
    try @import("std").testing.expect(canTransition(.downloading, .verifying));
    try @import("std").testing.expect(canTransition(.downloading, .canceled));
}

test "paused jobs re-enter queue before work resumes" {
    try @import("std").testing.expect(canTransition(.paused, .queued));
    try @import("std").testing.expect(!canTransition(.paused, .downloading));
}

test "terminal states cannot transition" {
    inline for (.{ State.completed, State.failed, State.canceled }) |terminal| {
        try @import("std").testing.expect(isTerminal(terminal));
        try @import("std").testing.expect(!canTransition(terminal, .queued));
    }
}

test "transition mutates state only after validation" {
    var state: State = .queued;
    try transition(&state, .resolving);
    try @import("std").testing.expectEqual(State.resolving, state);

    try @import("std").testing.expectError(error.InvalidTransition, transition(&state, .completed));
    try @import("std").testing.expectEqual(State.resolving, state);
}

test "progress distinguishes unknown, empty, and invalid totals" {
    const unknown = Progress{ .completed_bytes = 4 };
    const empty = Progress{ .total_bytes = 0 };
    const half = Progress{ .completed_bytes = 5, .total_bytes = 10 };
    const invalid = Progress{ .completed_bytes = 11, .total_bytes = 10 };
    try @import("std").testing.expect(unknown.fraction() == null);
    try @import("std").testing.expectEqual(@as(f64, 1), empty.fraction().?);
    try @import("std").testing.expectEqual(@as(f64, 0.5), half.fraction().?);
    try @import("std").testing.expect(invalid.fraction() == null);
}
