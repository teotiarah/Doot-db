//! Control-plane harness (M3).
//!
//! The real `Service` with a real control plane, behind the real event loop, so an HTTP client
//! we did not write can drive signup, verification, login, sessions, keys and the explorer end
//! to end.
//!
//! **The one substitution is the mail transport, and it is the only thing that can be.** A
//! verification code is delivered by ZeptoMail to a real inbox; a check script has neither.
//! So this harness drains the queue itself and prints each message as
//!
//!   MAIL <recipient> <code>
//!
//! which is exactly what the real `mail.Sender` would have sent, minus the third party. The
//! sender's own behaviour — backoff, retries, dropping, the payload shape — is covered by unit
//! tests in `service/mail.zig`, because none of it is observable from outside the process.
//!
//! Everything else is production code: the same handlers, the same Argon2id, the same
//! challenge table, the same rate limiters.
//!
//! **This is a fixture, not a server.** The deployable binary is `src/main.zig` (D63).
//!
//!   app [listen-addr] [workdir]

const std = @import("std");
const storage = @import("storage");
const control = @import("control");
const service = @import("service");
const server = @import("server");

const os = storage.os;

/// Dummy GitHub and ZeptoMail credentials. The OAuth exchange is never reached in this harness
/// — it would need GitHub — so the values only have to be non-empty for `boot`-shaped
/// validation to be satisfied.
const cfg: service.app.Config = .{
    .public_origin = "https://doot.test",
    .support_email = "support@doot.test",
    .github_client_id = "Iv1.harness",
    .github_client_secret = "ghs_harness",
    .zeptomail_token = "Zoho-enczapikey-harness",
};

/// Prints what the mail thread would have sent.
const Printer = struct {
    queue: *service.mail.Queue,
    clock: storage.clock.Clock,
    stopping: std.atomic.Value(bool) = .init(false),

    fn run(self: *Printer) void {
        while (!self.stopping.load(.acquire)) {
            while (self.queue.pop(self.clock.now())) |m| {
                // `std.debug.print` goes to stderr and is unbuffered, which is what a check
                // script reading the pipe needs -- the same channel `dataplane.zig` announces
                // its fixtures on.
                std.debug.print("MAIL {s} {s}\n", .{ m.to(), m.codeText() });
            }
            const req: std.os.linux.timespec = .{ .sec = 0, .nsec = 20 * 1_000_000 };
            _ = std.os.linux.nanosleep(&req, null);
        }
    }
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    _ = args.next();
    const addr = args.next() orelse "127.0.0.1:0";
    const workdir = args.next() orelse "/tmp/doot_app";

    var wall: storage.clock.Real = .{};
    const clk = wall.clock();

    os.mkdir(os.cwd, workdir) catch {};
    const dir_fd = try os.openDir(os.cwd, workdir);
    defer os.close(dir_fd);

    const store = try storage.Store.open(gpa, dir_fd, clk, .{});
    defer store.close();

    const ctl = try control.Control.open(gpa, dir_fd, clk);
    defer ctl.close();

    const idem = try gpa.create(service.IdempotencyTable);
    defer gpa.destroy(idem);
    idem.init();

    const replays = try gpa.create(service.ReplayBuffers);
    defer gpa.destroy(replays);
    replays.init();

    const challenges = try gpa.create(service.challenge.Table);
    defer gpa.destroy(challenges);
    challenges.* = try service.challenge.Table.init();

    const unauth = try gpa.create(service.ratelimit.Unauthenticated);
    defer gpa.destroy(unauth);
    unauth.* = try service.ratelimit.Unauthenticated.init();

    const dummy = try gpa.create(service.password.Dummy);
    defer gpa.destroy(dummy);
    dummy.* = try service.password.Dummy.init(gpa);

    const queue = try gpa.create(service.mail.Queue);
    defer gpa.destroy(queue);
    queue.* = .{};

    const emails = try gpa.create(service.app.EmailIndex);
    defer gpa.destroy(emails);
    emails.* = service.app.EmailIndex.init(gpa);
    defer emails.deinit();
    emails.rebuild(ctl);

    const subs = try gpa.create(service.app.Subscribers);
    defer gpa.destroy(subs);
    subs.* = .{};

    var app_state: service.app.State = .{
        .gpa = gpa,
        .cfg = cfg,
        .challenges = challenges,
        .unauth = unauth,
        .dummy = dummy,
        .queue = queue,
        .emails = emails,
        .subscribers = subs,
    };

    var svc = service.Service.init(.{
        .store = store,
        .control = ctl,
        .clock = clk,
        .cursor_secret = @splat(0x7a),
        .max_ttl_s = (storage.config.Options{}).max_ttl_s,
        .idempotency = idem,
        .replays = replays,
        .app = &app_state,
    });

    const loop = try server.Loop.init(gpa, .{
        .address = addr,
        .handler = svc.handler(),
        .stream = svc.streamSeam(),
        .clock = clk,
    });
    defer loop.deinit(gpa);

    var printer: Printer = .{ .queue = queue, .clock = clk };
    const printer_thread = try std.Thread.spawn(.{}, Printer.run, .{&printer});
    defer {
        printer.stopping.store(true, .release);
        printer_thread.join();
    }

    std.debug.print("LISTENING {d}\n", .{try loop.port()});

    try loop.run();
    return 0;
}
