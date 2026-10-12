//! Command-line entry point for the standalone download engine prototype.

const std = @import("std");
const download = @import("protocols/http/download.zig").download;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        std.debug.print("Usage: odm <http(s)-url> <destination>\n", .{});
        return;
    }
    if (args.len != 3) {
        std.debug.print("Usage: odm <http(s)-url> <destination>\n", .{});
        return error.InvalidArguments;
    }

    download(init.gpa, init.io, args[1], args[2]) catch |err| {
        std.debug.print("odm: {s}\n", .{errorMessage(err)});
        return err;
    };
}

fn errorMessage(err: anyerror) []const u8 {
    return if (err == error.UnsupportedScheme)
        "only http:// and https:// URLs are supported"
    else if (err == error.DestinationExists)
        "destination already exists; choose a different path"
    else if (err == error.UntrustedPartial)
        "partial file has no matching trusted resume journal; move or remove the .part file to restart"
    else if (err == error.ResumeUnsafeForUrl)
        "this URL may contain private data and cannot be safely resumed; remove its .part file to restart"
    else if (err == error.RepresentationChanged)
        "the remote file changed since the saved partial; its bytes were not appended"
    else if (err == error.InvalidResponseStatus)
        "the server returned an unsuccessful HTTP status"
    else if (err == error.InvalidContentRange)
        "the server returned an inconsistent byte range"
    else if (err == error.UnsupportedContentEncoding)
        "the server returned an encoded body; only identity responses are safe"
    else if (err == error.ResponseLengthMismatch)
        "the response ended before the declared file length"
    else if (err == error.InvalidResumeJournal)
        "resume metadata is invalid; move or remove the .part and .part.odm files to restart"
    else if (err == error.InvalidFullResponse)
        "the server returned partial content without a valid resume request"
    else
        @errorName(err);
}
