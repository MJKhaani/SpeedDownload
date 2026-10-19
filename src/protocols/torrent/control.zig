//! Shared worker cancellation contract for torrent discovery and transfer.
pub const CheckpointError = error{ TransferPauseRequested, TransferCancelRequested, TransferSchedulePaused };
pub const CheckpointCallback = *const fn (*anyopaque) CheckpointError!void;

pub fn checkpoint(callback: ?CheckpointCallback, context: ?*anyopaque) CheckpointError!void {
    if (callback) |check| if (context) |ctx| try check(ctx);
}
