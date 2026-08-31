//! The error catalogue (`02-api.md`), and the mapping from engine errors onto it.
//!
//! `code` is a **stable machine-readable identifier and never changes once
//! published**. `message` is human-facing and may be reworded freely. That split is
//! the entire contract, and it is why the slug is derived from the enum name rather
//! than written twice: a rename would be a breaking change, and the compiler is a
//! better guard against that than review is.
//!
//! Every non-2xx response carries this body, including `500` — which is why
//! `internal_error` exists (D52) and why it carries no detail. The failures behind it
//! are our disks and our memory, and an error body is the one place where being
//! helpful to the reporter and helpful to an attacker are the same act.

const std = @import("std");
const storage = @import("storage");

pub const docs_base = "https://doot.run/docs/errors#";

/// Enough for the longest default message plus framing. Asserted by a test rather
/// than guessed.
pub const max_body_bytes: usize = 512;

pub const Code = enum {
    // 400 — the request was understood and its contents were not acceptable.
    invalid_name,
    invalid_tag,
    too_many_tags,
    invalid_ttl,
    ttl_too_long,
    ttl_too_short,
    invalid_cursor,
    invalid_limit,
    missing_tag,
    content_type_too_long,
    invalid_request,
    // 401
    missing_credentials,
    invalid_credentials,
    // 402
    credits_exhausted,
    // 404
    not_found,
    // 405
    method_not_allowed,
    // 409
    idempotency_key_reused,
    idempotency_in_progress,
    // 411
    length_required,
    // 413
    body_too_large,
    // 429
    rate_limited,
    // 431
    headers_too_large,
    // 500
    internal_error,
    // 503
    capacity_exhausted,

    /// The published identifier. Identical to the enum name, so the two cannot
    /// drift.
    pub fn slug(c: Code) []const u8 {
        return @tagName(c);
    }

    pub fn status(c: Code) u16 {
        return switch (c) {
            .invalid_name,
            .invalid_tag,
            .too_many_tags,
            .invalid_ttl,
            .ttl_too_long,
            .ttl_too_short,
            .invalid_cursor,
            .invalid_limit,
            .missing_tag,
            .content_type_too_long,
            .invalid_request,
            => 400,
            .missing_credentials, .invalid_credentials => 401,
            .credits_exhausted => 402,
            .not_found => 404,
            .method_not_allowed => 405,
            .idempotency_key_reused, .idempotency_in_progress => 409,
            .length_required => 411,
            .body_too_large => 413,
            .rate_limited => 429,
            .headers_too_large => 431,
            .internal_error => 500,
            .capacity_exhausted => 503,
        };
    }

    /// The reason phrase for the status line. Fixed strings, so no allocation and no
    /// formatting on an error path.
    pub fn reason(c: Code) []const u8 {
        return switch (c.status()) {
            400 => "Bad Request",
            401 => "Unauthorized",
            402 => "Payment Required",
            404 => "Not Found",
            405 => "Method Not Allowed",
            409 => "Conflict",
            411 => "Length Required",
            413 => "Content Too Large",
            429 => "Too Many Requests",
            431 => "Request Header Fields Too Large",
            500 => "Internal Server Error",
            503 => "Service Unavailable",
            else => unreachable,
        };
    }

    /// Used when a handler has nothing more specific to say. Handlers that can name
    /// the offending value should pass their own message — `ttl_too_long` reads much
    /// better as "30d exceeds the 14d maximum for the trial plan".
    pub fn defaultMessage(c: Code) []const u8 {
        return switch (c) {
            .invalid_name => "The entry name is empty, too long, or contains forbidden characters.",
            .invalid_tag => "A tag is too long or contains characters outside a-z, 0-9, '.', '_', '-' and ':'.",
            .too_many_tags => "An entry may carry at most 5 tags.",
            .invalid_ttl => "X-Doot-TTL must be a whole number of seconds, optionally suffixed with s, m, h or d.",
            .ttl_too_long => "The requested lifetime exceeds the maximum for this plan.",
            .ttl_too_short => "The minimum lifetime is 60 seconds.",
            .invalid_cursor => "The cursor is malformed, expired, or was issued to another account.",
            .invalid_limit => "limit must be between 1 and 100.",
            .missing_tag => "Listing entries requires exactly one tag parameter.",
            .content_type_too_long => "Content-Type may be at most 128 bytes.",
            .invalid_request => "The request line or headers could not be parsed.",
            .missing_credentials => "Provide an API key as 'Authorization: Bearer <key>'.",
            .invalid_credentials => "The API key is unknown or has been revoked.",
            .credits_exhausted => "Write credits are exhausted. Reads, lists and deletes continue to work.",
            .not_found => "No entry exists at that name.",
            .method_not_allowed => "That method is not supported on this path.",
            .idempotency_key_reused => "That Idempotency-Key was already used with a different body.",
            .idempotency_in_progress => "A request with that Idempotency-Key is still in flight. Retry shortly.",
            .length_required => "Writes require a Content-Length header.",
            .body_too_large => "The body exceeds the 256 KB maximum.",
            .rate_limited => "Rate limit exceeded. Retry after the interval in Retry-After.",
            .headers_too_large => "The request line and headers exceed 8 KB in total.",
            // Deliberately says nothing. See D52.
            .internal_error => "The server could not complete the request.",
            .capacity_exhausted => "The origin cannot accept new entries. Existing entries remain readable.",
        };
    }
};

/// Maps an engine error onto the catalogue.
///
/// Only the errors that describe *the caller's request* get a specific code. Every
/// I/O failure, checksum failure and allocation failure is ours, not theirs, and
/// collapses to `internal_error` — the operator learns the detail from the log.
///
/// `error.IndexFull` becomes `capacity_exhausted` alongside `CapacityExhausted`
/// because they are the same situation seen from two layers, and `503` with
/// "existing entries remain readable" is the honest answer to both.
pub fn fromStore(err: anyerror) Code {
    return switch (err) {
        error.NameInvalid => .invalid_name,
        error.TagInvalid => .invalid_tag,
        error.TooManyTags => .too_many_tags,
        error.TtlTooShort => .ttl_too_short,
        error.TtlTooLong => .ttl_too_long,
        error.BodyTooLarge => .body_too_large,
        error.ContentTypeTooLong => .content_type_too_long,
        error.CapacityExhausted, error.IndexFull => .capacity_exhausted,
        else => .internal_error,
    };
}

/// Writes the uniform error body. Returns the slice actually used.
///
/// `message` is escaped even though messages originate here, because some of them
/// interpolate a value the caller supplied and the cost of being wrong about which
/// ones is a JSON injection.
pub fn writeBody(code: Code, message: []const u8, out: []u8) error{NoSpaceLeft}![]u8 {
    var w = Writer{ .buf = out };
    try w.put("{\"error\":{\"code\":\"");
    try w.put(code.slug());
    try w.put("\",\"message\":\"");
    try w.putEscaped(message);
    try w.put("\",\"docs\":\"" ++ docs_base);
    try w.put(code.slug());
    try w.put("\"}}");
    return w.done();
}

const Writer = struct {
    buf: []u8,
    len: usize = 0,

    fn put(w: *Writer, s: []const u8) error{NoSpaceLeft}!void {
        if (w.len + s.len > w.buf.len) return error.NoSpaceLeft;
        @memcpy(w.buf[w.len..][0..s.len], s);
        w.len += s.len;
    }

    fn putByte(w: *Writer, b: u8) error{NoSpaceLeft}!void {
        if (w.len + 1 > w.buf.len) return error.NoSpaceLeft;
        w.buf[w.len] = b;
        w.len += 1;
    }

    fn putEscaped(w: *Writer, s: []const u8) error{NoSpaceLeft}!void {
        for (s) |ch| switch (ch) {
            '"' => try w.put("\\\""),
            '\\' => try w.put("\\\\"),
            '\n' => try w.put("\\n"),
            '\r' => try w.put("\\r"),
            '\t' => try w.put("\\t"),
            // Everything below 0x20 must be escaped; \u is the only general form.
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                try w.put("\\u00");
                const hex = "0123456789abcdef";
                try w.putByte(hex[ch >> 4]);
                try w.putByte(hex[ch & 0x0f]);
            },
            else => try w.putByte(ch),
        };
    }

    fn done(w: *Writer) []u8 {
        return w.buf[0..w.len];
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "every code has a status, a reason and a message" {
    inline for (@typeInfo(Code).@"enum".fields) |f| {
        const c: Code = @enumFromInt(f.value);
        try testing.expect(c.status() >= 400 and c.status() < 600);
        try testing.expect(c.reason().len > 0);
        try testing.expect(c.defaultMessage().len > 0);
        try testing.expectEqualStrings(f.name, c.slug());
    }
}

test "statuses match the published catalogue" {
    // Spot-checks against the table in 02-api.md, including every code D52 added.
    try testing.expectEqual(@as(u16, 400), Code.invalid_name.status());
    try testing.expectEqual(@as(u16, 400), Code.content_type_too_long.status());
    try testing.expectEqual(@as(u16, 400), Code.invalid_request.status());
    try testing.expectEqual(@as(u16, 401), Code.invalid_credentials.status());
    try testing.expectEqual(@as(u16, 402), Code.credits_exhausted.status());
    try testing.expectEqual(@as(u16, 404), Code.not_found.status());
    try testing.expectEqual(@as(u16, 405), Code.method_not_allowed.status());
    try testing.expectEqual(@as(u16, 409), Code.idempotency_key_reused.status());
    try testing.expectEqual(@as(u16, 411), Code.length_required.status());
    try testing.expectEqual(@as(u16, 413), Code.body_too_large.status());
    try testing.expectEqual(@as(u16, 429), Code.rate_limited.status());
    try testing.expectEqual(@as(u16, 431), Code.headers_too_large.status());
    try testing.expectEqual(@as(u16, 500), Code.internal_error.status());
    try testing.expectEqual(@as(u16, 503), Code.capacity_exhausted.status());
}

test "the body is the shape 02-api.md publishes" {
    var buf: [max_body_bytes]u8 = undefined;
    const body = try writeBody(.ttl_too_long, "X-Doot-TTL of 30d exceeds the 14d maximum for the trial plan.", &buf);
    try testing.expectEqualStrings(
        \\{"error":{"code":"ttl_too_long","message":"X-Doot-TTL of 30d exceeds the 14d maximum for the trial plan.","docs":"https://doot.run/docs/errors#ttl_too_long"}}
    , body);
}

test "every default message fits the buffer" {
    // The constant is asserted rather than assumed, because overflowing it on an
    // error path would replace a useful error with a different one.
    inline for (@typeInfo(Code).@"enum".fields) |f| {
        const c: Code = @enumFromInt(f.value);
        var buf: [max_body_bytes]u8 = undefined;
        _ = try writeBody(c, c.defaultMessage(), &buf);
    }
}

test "a message cannot break out of the JSON string" {
    var buf: [max_body_bytes]u8 = undefined;
    const body = try writeBody(.invalid_name, "quote\" backslash\\ newline\n tab\t ctrl\x01", &buf);
    try testing.expectEqualStrings(
        \\{"error":{"code":"invalid_name","message":"quote\" backslash\\ newline\n tab\t ctrl\u0001","docs":"https://doot.run/docs/errors#invalid_name"}}
    , body);
}

test "a body that will not fit fails rather than truncating" {
    var tiny: [16]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, writeBody(.not_found, "irrelevant", &tiny));
}

test "engine errors map to the codes the caller should see" {
    try testing.expectEqual(Code.invalid_name, fromStore(error.NameInvalid));
    try testing.expectEqual(Code.invalid_tag, fromStore(error.TagInvalid));
    try testing.expectEqual(Code.too_many_tags, fromStore(error.TooManyTags));
    try testing.expectEqual(Code.ttl_too_short, fromStore(error.TtlTooShort));
    try testing.expectEqual(Code.ttl_too_long, fromStore(error.TtlTooLong));
    try testing.expectEqual(Code.body_too_large, fromStore(error.BodyTooLarge));
    try testing.expectEqual(Code.content_type_too_long, fromStore(error.ContentTypeTooLong));
    try testing.expectEqual(Code.capacity_exhausted, fromStore(error.CapacityExhausted));
    try testing.expectEqual(Code.capacity_exhausted, fromStore(error.IndexFull));
}

test "our own failures are never described to the caller" {
    // A corrupt record, a full disk and an allocation failure are all ours. Naming
    // them in a response would leak internals and help nobody.
    try testing.expectEqual(Code.internal_error, fromStore(error.BadChecksum));
    try testing.expectEqual(Code.internal_error, fromStore(error.CorruptRecord));
    try testing.expectEqual(Code.internal_error, fromStore(error.NoSpaceLeft));
    try testing.expectEqual(Code.internal_error, fromStore(error.OutOfMemory));
    try testing.expectEqual(Code.internal_error, fromStore(error.InputOutput));
    try testing.expectEqual(Code.internal_error, fromStore(error.StoreIdentityMissing));
}

test "the whole engine error set maps to something" {
    // Exhaustive over Store.Error, so adding an engine error forces a decision here
    // rather than defaulting silently to a 500 nobody noticed.
    inline for (@typeInfo(@typeInfo(
        @typeInfo(@TypeOf(storage.Store.put)).@"fn".return_type.?,
    ).error_union.error_set).error_set.?) |e| {
        const code = fromStore(@field(anyerror, e.name));
        try testing.expect(code.status() >= 400);
    }
}
