//! Calendar dates: pure proleptic-Gregorian maths, ISO 8601 parse / format,
//! no allocation and no clock. (Where "today" comes from is the app's
//! business: see `DateField`'s `set_today`, fed from a `clock` effect.)

const std = @import("std");

pub const Date = struct {
    year: i32,
    /// 1 ... 12
    month: u8,
    /// 1 ... daysInMonth
    day: u8,

    pub fn eql(a: Date, b: Date) bool {
        return a.year == b.year and a.month == b.month and a.day == b.day;
    }

    pub fn order(a: Date, b: Date) std.math.Order {
        if (a.year != b.year) return std.math.order(a.year, b.year);
        if (a.month != b.month) return std.math.order(a.month, b.month);
        return std.math.order(a.day, b.day);
    }
};

pub const month_names = [12][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
/// Monday-first weekday headings.
pub const weekday_short = [7][]const u8{ "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" };

pub fn isLeap(year: i32) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
}

pub fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        else => if (isLeap(year)) 29 else 28,
    };
}

pub fn valid(d: Date) bool {
    return d.month >= 1 and d.month <= 12 and d.day >= 1 and d.day <= daysInMonth(d.year, d.month);
}

/// Days since 1970-01-01 (Howard Hinnant's `days_from_civil`).
pub fn toDays(d: Date) i64 {
    const y: i64 = d.year - @as(i32, if (d.month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = @mod(@as(i64, d.month) + 9, 12); // March = 0
    const doy = @divFloor(153 * mp + 2, 5) + d.day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn fromDays(days: i64) Date {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = @intCast(y + @as(i64, if (m <= 2) 1 else 0)), .month = @intCast(m), .day = @intCast(d) };
}

/// 0 = Monday ... 6 = Sunday.
pub fn weekday(d: Date) u8 {
    return @intCast(@mod(toDays(d) + 3, 7)); // 1970-01-01 was a Thursday
}

pub fn addDays(d: Date, n: i64) Date {
    return fromDays(toDays(d) + n);
}

/// Add `n` months, clamping the day to the target month's length (Jan 31 + 1 = Feb 28/29).
pub fn addMonths(d: Date, n: i32) Date {
    const total = d.year * 12 + (@as(i32, d.month) - 1) + n;
    const y = @divFloor(total, 12);
    const m: u8 = @intCast(@mod(total, 12) + 1);
    return .{ .year = y, .month = m, .day = @min(d.day, daysInMonth(y, m)) };
}

pub fn addYears(d: Date, n: i32) Date {
    return addMonths(d, n * 12);
}

/// The local calendar date for a unix time in ms and a UTC offset in minutes
/// (the shape a `clock` effect result has).
pub fn fromUnixMs(unix_ms: i64, utc_offset_min: i32) Date {
    const local_ms = unix_ms + @as(i64, utc_offset_min) * 60_000;
    return fromDays(@divFloor(local_ms, 86_400_000));
}

/// Strict `YYYY-MM-DD` (4 digits, real calendar date); null otherwise.
pub fn parseIso(text: []const u8) ?Date {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return null;
    const y = std.fmt.parseInt(u16, text[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(u8, text[5..7], 10) catch return null;
    const da = std.fmt.parseInt(u8, text[8..10], 10) catch return null;
    // parseInt accepts a leading '+'; keep the digits-only shape strict.
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9 }) |i| if (!std.ascii.isDigit(text[i])) return null;
    const d: Date = .{ .year = y, .month = mo, .day = da };
    return if (valid(d)) d else null;
}

/// `YYYY-MM-DD` into `buf` (>= 10 bytes); years outside 0..9999 clamp.
pub fn formatIso(d: Date, buf: []u8) []const u8 {
    const y: u32 = @intCast(std.math.clamp(d.year, 0, 9999));
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ y, d.month, d.day }) catch "";
}

const testing = std.testing;






