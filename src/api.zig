//! Doot's request layer.
//!
//! Everything here is a pure function over caller-supplied bytes: the error
//! catalogue, the parsing grammars D47 settled, server-assigned names, and the signed
//! pagination cursor D46 specified. No allocation, no clock, no I/O, no sockets — so
//! the whole surface is exactly testable before an event loop exists.
//!
//! The HTTP transport that drives these lives in `src/server/` and the seven endpoint
//! handlers in `src/service/`; both are built. What remains of M2 is the origin binary
//! that runs them (D63) and the edge.
//!
//! Specification: `docs/02-api.md` and `docs/03-data-model.md`. Decisions:
//! `docs/07-decisions.md` D46 (cursors), D47 (parsing), D52 (the error codes the
//! catalogue was missing).

const std = @import("std");

pub const errors = @import("api/errors.zig");
pub const parse = @import("api/parse.zig");
pub const ulid = @import("api/ulid.zig");
pub const cursor = @import("api/cursor.zig");
pub const email = @import("api/email.zig");
pub const secret = @import("api/secret.zig");
pub const cookie = @import("api/cookie.zig");
pub const form = @import("api/form.zig");

pub const Code = errors.Code;
pub const TagSet = parse.TagSet;
pub const Ulid = ulid.Ulid;

test {
    _ = errors;
    _ = parse;
    _ = ulid;
    _ = cursor;
    _ = email;
    _ = secret;
    _ = cookie;
    _ = form;
}
