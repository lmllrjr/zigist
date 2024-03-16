const std = @import("std");
const http = std.http;
const log = std.log;
const testing = std.testing;
const time = std.time;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Client = http.Client;
const env = @import("env");
const zigist_http = @import("http");

const stdout = std.io.getStdOut().writer();

const ZigistError = error{
    FormatFailure,
    MissingEnvironmentVariable,
    ParseFailure,
    Internal,
};

const Joke = struct {
    type: []const u8,

    joke: ?[]const u8 = null,
    setup: ?[]const u8 = null,
    delivery: ?[]const u8 = null,
};

// TODO: refactor more
pub fn main() !void {
    // https://ziglang.org/documentation/master/#Choosing-an-Allocator
    // var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // defer arena.deinit();
    // const alloc = arena.allocator();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const token = env.get(env.GH_TOKEN) catch |err| {
        log.err("environment variable GH_TOKEN not found", .{});
        return err;
    };
    const gist_id = env.get(env.GIST_ID) catch |err| {
        log.err("environment variable GIST_ID not found", .{});
        return err;
    };

    var client = zigist_http.Client.init(alloc);
    defer client.deinit(); // arena

    const body = client.getJoke(alloc) catch |err| {
        log.err("request could not be finished", .{});
        return err;
    };

    defer alloc.free(body); // arena

    const joke = try std.json.parseFromSlice(Joke, alloc, body, .{ .ignore_unknown_fields = true });
    defer joke.deinit(); // arena

    const parsedData = joke.value;

    var payload: []u8 = undefined;

    // convert epoch unix timestamp to datetime
    const dateTime = timestamp2DateTime(@intCast(time.timestamp()));
    const timestamp = try dateTime2String(alloc, dateTime);
    defer alloc.free(timestamp); // arena

    // TODO: builder pattern
    if (std.mem.eql(u8, parsedData.type, "single")) {
        var singleJoke: []u8 = undefined;
        if (containsNewLine(parsedData.joke.?)) {
            singleJoke = try substituteNewLines(alloc, parsedData.joke.?);
        } else {
            singleJoke = try splitStringIntoLines(alloc, parsedData.joke.?, false);
        }
        defer alloc.free(singleJoke); // arena

        payload = std.fmt.allocPrint(
            alloc,
            \\ {{
            \\ "files":{{
            \\      "NEWS.md":{{
            \\          "content":"{s}\n\n> {s}"
            \\      }}
            \\ }}
        ,
            .{ singleJoke, timestamp },
        ) catch {
            return ZigistError.FormatFailure;
        };

        log.info("single joke: {?s}\n", .{parsedData.joke});
    } else {
        const jokeSetup = try splitStringIntoLines(alloc, parsedData.setup.?, false);
        const jokeDelivery = try splitStringIntoLines(alloc, parsedData.delivery.?, true);
        defer alloc.free(jokeSetup); // arena
        defer alloc.free(jokeDelivery); // arena

        payload = std.fmt.allocPrint(
            alloc,
            \\ {{
            \\ "files":{{
            \\      "NEWS.md":{{
            \\          "content":"{s}\n* {s}\n\n> {s}"
            \\      }}
            \\ }}
        ,
            .{ jokeSetup, jokeDelivery, timestamp },
        ) catch {
            return ZigistError.FormatFailure;
        };

        log.info("setup: {?s}\n", .{parsedData.setup.?});
        log.info("delivery: {?s}\n", .{parsedData.delivery.?});
    }
    defer alloc.free(payload); // arena
    // TODO: print/render funcs
    try stdout.print("\n\npayload: {s}\n\n", .{payload});

    const resp = try client.putGist(alloc, gist_id, token, payload);

    try stdout.print("\n\n", .{});
    if (resp.status == http.Status.ok) {
        log.info("gist updated successfully: {u}\n", .{resp.status});
    } else {
        log.err("something went wrong: {u}\n", .{resp.status});
        log.err("response: reason: {s}\n", .{resp.reason});
        return ZigistError.Internal;
    }
}

// TODO: naming
fn substituteNewLines(alloc: Allocator, s: []const u8) ![]u8 {
    var list = std.ArrayList(u8).init(alloc);
    defer list.deinit();

    for (s) |c| {
        if (c == 34) {
            try list.append('\\');
        }
        if (c == '\n') {
            try list.append('\\');
            try list.append('n');
            continue;
        } else {
            try list.append(c);
        }
    }

    return list.toOwnedSlice();
}

// TODO: naming
fn splitStringIntoLines(alloc: Allocator, s: []const u8, punchline: bool) ![]u8 {
    var list = std.ArrayList(u8).init(alloc);
    defer list.deinit();

    var count: u32 = 0;
    for (s) |c| {
        if (c == 34) {
            try list.append('\\');
        }
        if (c == 32 and count > 35) {
            try list.append(' ');
            try list.append(' ');
            try list.append('\\');
            try list.append('n');
            if (punchline) {
                try list.append(' ');
                try list.append(' ');
            }
            count = 0;
        } else {
            try list.append(c);
            count += 1;
        }
    }

    return list.toOwnedSlice();
}

fn containsNewLine(input: []const u8) bool {
    var containsNewL = false;
    var index: usize = 0;
    while (index < input.len) {
        if (input[index] == '\n') {
            containsNewL = true;
            break;
        }
        index += 1;
    }
    return containsNewL;
}

test "ok - substituteNewLines" {
    var alloc = testing.allocator;
    const joke =
        \\a string
        \\with
        \\new
        \\line characters
    ;

    const exp = try substituteNewLines(alloc, joke);
    defer alloc.free(exp);

    try testing.expect(std.mem.eql(u8, "a string\\nwith\\nnew\\nline characters", exp));
}

test "ok - splitStringIntoLines punchline" {
    var alloc = testing.allocator;
    const punchline = "a really really long punchline that needs to be split";

    const exp = try splitStringIntoLines(alloc, punchline, true);
    defer alloc.free(exp);

    try testing.expect(std.mem.eql(u8, "a really really long punchline that needs  \\n  to be split", exp));

    const punchline2 = "a really really long punchline that needs to be split multiple times, not only once ...crazy isn't it?";

    const exp2 = try splitStringIntoLines(alloc, punchline2, true);
    defer alloc.free(exp2);

    try testing.expect(std.mem.eql(u8, "a really really long punchline that needs  \\n  to be split multiple times, not only  \\n  once ...crazy isn't it?", exp2));
}

test "ok - splitStringIntoLines question" {
    var alloc = testing.allocator;

    const res = try splitStringIntoLines(alloc, "a really really totally crazy long sentence that needs to be split in multiple lines", false);
    defer alloc.free(res);

    try testing.expect(std.mem.eql(u8, "a really really totally crazy long sentence  \\nthat needs to be split in multiple lines", res));
}

// date time handling
pub const DateTime = struct {
    day: u8,
    month: u8,
    year: u16,
    hour: u8,
    minute: u8,
    second: u8,
};

/// timestamp2DateTime converts a unix epoch timestamp to a DateTime object.
pub fn timestamp2DateTime(ts: u64) DateTime {
    const SECONDS_PER_DAY = 86400;
    const DAYS_PER_YEAR = 365;
    const DAYS_IN_4YEARS = 1461;
    const DAYS_IN_100YEARS = 36524;
    const DAYS_IN_400YEARS = 146097;
    const DAYS_BEFORE_EPOCH = 719468;

    const seconds_since_midnight: u64 = @rem(ts, SECONDS_PER_DAY);
    var day_n: u64 = DAYS_BEFORE_EPOCH + ts / SECONDS_PER_DAY;
    var temp: u64 = 0;

    temp = 4 * (day_n + DAYS_IN_100YEARS + 1) / DAYS_IN_400YEARS - 1;
    var year: u16 = @intCast(100 * temp);
    day_n -= DAYS_IN_100YEARS * temp + temp / 4;

    temp = 4 * (day_n + DAYS_PER_YEAR + 1) / DAYS_IN_4YEARS - 1;
    year += @intCast(temp);
    day_n -= DAYS_PER_YEAR * temp + temp / 4;

    var month: u8 = @intCast((5 * day_n + 2) / 153);
    const day: u8 = @intCast(day_n - (@as(u64, @intCast(month)) * 153 + 2) / 5 + 1);

    month += 3;
    if (month > 12) {
        month -= 12;
        year += 1;
    }

    return DateTime{ .year = year, .month = month, .day = day, .hour = @intCast(seconds_since_midnight / 3600), .minute = @intCast(seconds_since_midnight % 3600 / 60), .second = @intCast(seconds_since_midnight % 60) };
}

fn dateTime2String(alloc: Allocator, dt: DateTime) ![]u8 {
    const ts = try std.fmt.allocPrint(alloc, "{:0>2}.{:0>2}.{:0>4} {:0>2}:{:0>2}:{:0>2}", .{ dt.day, dt.month, dt.year, dt.hour, dt.minute, dt.second });

    return ts;
}

test "datetime 2 string" {
    const alloc = testing.allocator;
    const actual = try dateTime2String(alloc, DateTime{ .year = 2023, .month = 8, .day = 4, .hour = 9, .minute = 3, .second = 2 });
    defer alloc.free(actual);

    try testing.expectEqualStrings("04.08.2023 09:03:02", actual);
}

test "GMT and localtime" {
    // Summer, CEST
    try std.testing.expectEqual(DateTime{ .year = 2020, .month = 8, .day = 28, .hour = 9, .minute = 32, .second = 27 }, timestamp2DateTime(1598607147));

    // Winter, CET
    try std.testing.expectEqual(DateTime{ .year = 2020, .month = 11, .day = 1, .hour = 5, .minute = 6, .second = 7 }, timestamp2DateTime(1604207167));
}
