const std = @import("std");

/// A bounded delay shared by the HTTP clients and the queue scheduler.
pub const Hint = std.atomic.Value(u32);
pub const max_seconds: u32 = 3600;

pub fn record(hint: ?*Hint, header: ?[]const u8, now_unix_seconds: i64) void {
    const target = hint orelse return;
    const value = header orelse return;
    const seconds = parse(value, now_unix_seconds) orelse return;
    var current = target.load(.acquire);
    while (current < seconds) {
        if (target.cmpxchgWeak(current, seconds, .acq_rel, .acquire)) |observed| {
            current = observed;
        } else return;
    }
}

fn parse(raw: []const u8, now: i64) ?u32 {
    const value = std.mem.trim(u8, raw, " \t");
    if (value.len == 0) return null;
    if (std.ascii.isDigit(value[0])) {
        var seconds: u32 = 0;
        for (value) |digit| {
            if (!std.ascii.isDigit(digit)) return null;
            seconds = @min(max_seconds, seconds *| 10 +| (digit - '0'));
        }
        return seconds;
    }
    // IMF-fixdate: Sun, 06 Nov 1994 08:49:37 GMT.
    if (value.len != 29 or value[3] != ',' or value[4] != ' ' or value[7] != ' ' or
        value[11] != ' ' or value[16] != ' ' or value[19] != ':' or value[22] != ':' or
        !std.mem.eql(u8, value[25..], " GMT")) return null;
    const day = std.fmt.parseInt(u8, value[5..7], 10) catch return null;
    const year = std.fmt.parseInt(i32, value[12..16], 10) catch return null;
    const hour = std.fmt.parseInt(u8, value[17..19], 10) catch return null;
    const minute = std.fmt.parseInt(u8, value[20..22], 10) catch return null;
    const second = std.fmt.parseInt(u8, value[23..25], 10) catch return null;
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    var month: u8 = 0;
    for (months, 1..) |name, index| if (std.mem.eql(u8, value[8..11], name)) {
        month = @intCast(index);
        break;
    };
    if (month == 0 or year < 1970 or day == 0 or hour > 23 or minute > 59 or second > 59) return null;
    const month_lengths = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const leap = @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    const max_day = month_lengths[month - 1] + @as(u8, @intFromBool(month == 2 and leap));
    if (day > max_day) return null;
    const days = daysFromCivil(year, month, day);
    const timestamp = days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
    if (timestamp <= now) return 0;
    return @intCast(@min(timestamp - now, max_seconds));
}

fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    const y: i64 = @as(i64, year) - @as(i64, @intFromBool(month <= 2));
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (m + (if (m > 2) @as(i64, -3) else @as(i64, 9))) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}
