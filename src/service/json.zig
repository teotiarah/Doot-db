//! A minimal JSON writer for response bodies.
//!
//! Bounded and allocation-free, over a caller-supplied buffer. `api/errors.zig` has its
//! own private version of this for the uniform error body; this is the one the endpoints
//! that return documents use — `whoami`, the list page, and `healthz`.
//!
//! It escapes, and that is the reason it exists rather than a series of `bufPrint` calls.
//! Two of the strings it writes come from the caller: an entry name is any printable
//! ASCII including `"` and `\` (`03-data-model.md`), and a stored `Content-Type` is
//! echoed back verbatim. Interpolating either without escaping is a JSON injection, and
//! the list endpoint interpolates both, once per entry.

const std = @import("std");

pub const Error = error{NoSpaceLeft};

pub const Writer = struct {
    buf: []u8,
    len: usize = 0,
    /// Whether the current object or array already holds something, so separators are
    /// emitted for the caller instead of counted by it.
    needs_comma: bool = false,

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }

    pub fn done(w: *const Writer) []const u8 {
        return w.buf[0..w.len];
    }

    // -- structure --

    pub fn beginObject(w: *Writer) Error!void {
        try w.separate();
        try w.raw("{");
        w.needs_comma = false;
    }

    pub fn endObject(w: *Writer) Error!void {
        try w.raw("}");
        w.needs_comma = true;
    }

    pub fn beginArray(w: *Writer) Error!void {
        try w.separate();
        try w.raw("[");
        w.needs_comma = false;
    }

    pub fn endArray(w: *Writer) Error!void {
        try w.raw("]");
        w.needs_comma = true;
    }

    /// Starts a member. The value follows as its own call.
    pub fn key(w: *Writer, name: []const u8) Error!void {
        try w.separate();
        try w.raw("\"");
        try w.raw(name); // Always a literal in this codebase, never caller input.
        try w.raw("\":");
        w.needs_comma = false;
    }

    // -- values --

    pub fn string(w: *Writer, value: []const u8) Error!void {
        try w.separate();
        try w.raw("\"");
        try w.escaped(value);
        try w.raw("\"");
        w.needs_comma = true;
    }

    pub fn number(w: *Writer, value: u64) Error!void {
        try w.separate();
        var scratch: [20]u8 = undefined;
        try w.raw(std.fmt.bufPrint(&scratch, "{d}", .{value}) catch unreachable);
        w.needs_comma = true;
    }

    pub fn boolean(w: *Writer, value: bool) Error!void {
        try w.separate();
        try w.raw(if (value) "true" else "false");
        w.needs_comma = true;
    }

    // -- shorthands, because every body here is mostly flat members --

    pub fn stringMember(w: *Writer, name: []const u8, value: []const u8) Error!void {
        try w.key(name);
        try w.string(value);
    }

    pub fn numberMember(w: *Writer, name: []const u8, value: u64) Error!void {
        try w.key(name);
        try w.number(value);
    }

    // -- internals --

    fn separate(w: *Writer) Error!void {
        if (w.needs_comma) try w.raw(",");
    }

    fn raw(w: *Writer, s: []const u8) Error!void {
        if (w.len + s.len > w.buf.len) return error.NoSpaceLeft;
        @memcpy(w.buf[w.len..][0..s.len], s);
        w.len += s.len;
    }

    fn byte(w: *Writer, b: u8) Error!void {
        if (w.len + 1 > w.buf.len) return error.NoSpaceLeft;
        w.buf[w.len] = b;
        w.len += 1;
    }

    fn escaped(w: *Writer, s: []const u8) Error!void {
        for (s) |ch| switch (ch) {
            '"' => try w.raw("\\\""),
            '\\' => try w.raw("\\\\"),
            '\n' => try w.raw("\\n"),
            '\r' => try w.raw("\\r"),
            '\t' => try w.raw("\\t"),
            // Everything below 0x20 has to be escaped and `\u` is the only general form.
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                try w.raw("\\u00");
                const hex = "0123456789abcdef";
                try w.byte(hex[ch >> 4]);
                try w.byte(hex[ch & 0x0f]);
            },
            else => try w.byte(ch),
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a flat object" {
    var buf: [128]u8 = undefined;
    var w = Writer.init(&buf);
    try w.beginObject();
    try w.stringMember("status", "ok");
    try w.numberMember("seq", 42);
    try w.endObject();
    try testing.expectEqualStrings("{\"status\":\"ok\",\"seq\":42}", w.done());
}

test "nested objects and arrays get their separators right" {
    var buf: [256]u8 = undefined;
    var w = Writer.init(&buf);
    try w.beginObject();
    try w.key("entries");
    try w.beginArray();
    for ([_][]const u8{ "a", "b" }) |name| {
        try w.beginObject();
        try w.stringMember("name", name);
        try w.endObject();
    }
    try w.endArray();
    try w.key("credits");
    try w.beginObject();
    try w.numberMember("remaining", 9187);
    try w.endObject();
    try w.endObject();
    try testing.expectEqualStrings(
        \\{"entries":[{"name":"a"},{"name":"b"}],"credits":{"remaining":9187}}
    , w.done());
}

test "an empty array and an empty object are still valid" {
    var buf: [64]u8 = undefined;
    var w = Writer.init(&buf);
    try w.beginObject();
    try w.key("entries");
    try w.beginArray();
    try w.endArray();
    try w.endObject();
    try testing.expectEqualStrings("{\"entries\":[]}", w.done());
}

test "a name cannot break out of its string" {
    // The case that matters: entry names are any printable ASCII, quotes and backslashes
    // included (03-data-model.md), and the list endpoint interpolates one per entry.
    var buf: [256]u8 = undefined;
    var w = Writer.init(&buf);
    try w.beginObject();
    try w.stringMember("name", "evil\",\"admin\":true,\"x\":\"");
    try w.endObject();
    try testing.expectEqualStrings(
        \\{"name":"evil\",\"admin\":true,\"x\":\""}
    , w.done());
}

test "control characters and backslashes are escaped" {
    var buf: [256]u8 = undefined;
    var w = Writer.init(&buf);
    try w.string("tab\there\nnl\\bs\x01ctl\x1f");
    try testing.expectEqualStrings(
        \\"tab\there\nnl\\bs\u0001ctl\u001f"
    , w.done());
}

test "a content type is escaped too, because it is stored verbatim" {
    var buf: [256]u8 = undefined;
    var w = Writer.init(&buf);
    try w.beginObject();
    try w.stringMember("content_type", "text/plain;x=\"y\"");
    try w.endObject();
    try testing.expectEqualStrings(
        \\{"content_type":"text/plain;x=\"y\""}
    , w.done());
}

test "booleans and large numbers" {
    var buf: [128]u8 = undefined;
    var w = Writer.init(&buf);
    try w.beginObject();
    try w.key("ok");
    try w.boolean(true);
    try w.numberMember("max", std.math.maxInt(u64));
    try w.endObject();
    try testing.expectEqualStrings(
        "{\"ok\":true,\"max\":18446744073709551615}",
        w.done(),
    );
}

test "running out of room fails rather than truncating" {
    // A truncated body is invalid JSON that a client would report as a server fault, so
    // the caller has to learn about it and answer with a 500 instead.
    var tiny: [8]u8 = undefined;
    var w = Writer.init(&tiny);
    try w.beginObject();
    try testing.expectError(error.NoSpaceLeft, w.stringMember("name", "far too long"));
}

test "escaping cannot overrun the buffer either" {
    var tiny: [6]u8 = undefined;
    var w = Writer.init(&tiny);
    try testing.expectError(error.NoSpaceLeft, w.string("\x01\x02\x03"));
}
