#!/usr/bin/env bash
# Install the pinned Zig toolchain for Doot, verify its hash, and apply the
# required stdlib patch. Idempotent: safe to re-run.
#
# Usage: toolchain/setup.sh [install-prefix]      (default: /projects/toolchain)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${1:-/projects/toolchain}"
ZIG_DIR="$PREFIX/zig"

# shellcheck disable=SC1091
source "$HERE/zig.lock"

echo "==> Doot toolchain: Zig $ZIG_VERSION -> $ZIG_DIR"

if [ -x "$ZIG_DIR/zig" ] && [ "$("$ZIG_DIR/zig" version)" = "$ZIG_VERSION" ]; then
  echo "    already installed"
else
  mkdir -p "$PREFIX/dl" "$ZIG_DIR"
  cd "$PREFIX/dl"

  echo "==> downloading $ZIG_TARBALL_URL"
  curl -fsSLo zig.tar.xz "$ZIG_TARBALL_URL"

  actual="$(sha256sum zig.tar.xz | cut -d' ' -f1)"
  if [ "$actual" != "$ZIG_TARBALL_SHA256" ]; then
    echo "!!! sha256 mismatch" >&2
    echo "    expected $ZIG_TARBALL_SHA256" >&2
    echo "    actual   $actual" >&2
    exit 1
  fi
  echo "    sha256 verified"

  # xz is not present on every image; python's lzma always is.
  if command -v xz >/dev/null 2>&1; then
    tar -xJf zig.tar.xz -C "$ZIG_DIR" --strip-components=1
  else
    python3 -c "
import lzma, shutil
with lzma.open('zig.tar.xz') as f, open('zig.tar','wb') as o:
    shutil.copyfileobj(f, o)
"
    tar -xf zig.tar -C "$ZIG_DIR" --strip-components=1
    rm -f zig.tar
  fi
  rm -f zig.tar.xz
  echo "    extracted $("$ZIG_DIR/zig" version)"
fi

# ---------------------------------------------------------------------------
# Stdlib patch. std.Io.Uring does not compile in 0.16.0 as shipped: two
# exhaustive error switches omit error.ReadOnlyFileSystem, so merely calling
# Uring.io() fails semantic analysis. See docs/07-decisions.md D26.
# ---------------------------------------------------------------------------
echo "==> applying stdlib patches"
for rel in $ZIG_PATCHES; do
  patch_file="$HERE/$rel"
  echo "    $rel"
  python3 - "$patch_file" "$ZIG_DIR" <<'PY'
import re, sys

patch_path, zig_dir = sys.argv[1], sys.argv[2]
text = open(patch_path).read()

# Minimal unified-diff applier. Exact-context only, no fuzz: a patch that does
# not apply cleanly must fail loudly rather than land somewhere plausible.
file_re = re.compile(r'^--- a/(.+?)\n\+\+\+ b/(.+?)\n', re.M)
m = file_re.search(text)
if not m:
    sys.exit("patch: no file header found")
target = f"{zig_dir}/{m.group(2)}"
body = text[m.end():]

hunks = []
for hm in re.finditer(r'^@@ -(\d+),(\d+) \+(\d+),(\d+) @@.*?\n', body, re.M):
    start = hm.end()
    nxt = re.search(r'^@@ ', body[start:], re.M)
    chunk = body[start:start + nxt.start()] if nxt else body[start:]
    hunks.append((int(hm.group(1)), chunk))

lines = open(target).read().splitlines(keepends=True)
applied = skipped = 0

# Content must match exactly; position may drift, because an earlier hunk in
# the same patch shifts every line number after it. Same tolerance real patch
# applies, without accepting fuzzy content.
DRIFT = 64

def locate(block, expected):
    if not block:
        return None
    for delta in range(0, DRIFT + 1):
        for i in {expected + delta, expected - delta}:
            if 0 <= i and lines[i:i + len(block)] == block:
                return i
    return None

for old_start, chunk in reversed(hunks):
    old, new = [], []
    for ln in chunk.splitlines(keepends=True):
        if not ln.strip('\n'):
            old.append('\n'); new.append('\n'); continue
        tag, rest = ln[0], ln[1:]
        if tag == ' ':
            old.append(rest); new.append(rest)
        elif tag == '-':
            old.append(rest)
        elif tag == '+':
            new.append(rest)

    expected = old_start - 1
    at = locate(old, expected)
    if at is not None:
        lines[at:at + len(old)] = new
        applied += 1
    elif locate(new, expected) is not None:
        skipped += 1                       # already applied
    else:
        sys.exit(f"patch: hunk at line {old_start} does not apply cleanly to {target}")

if applied:
    open(target, 'w').writelines(lines)
print(f"      {applied} hunk(s) applied, {skipped} already present")
PY
done

# ---------------------------------------------------------------------------
# Prove the toolchain works, including the thing the patch fixes.
# ---------------------------------------------------------------------------
echo "==> verifying"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat > "$work/verify.zig" <<'EOF'
const std = @import("std");
pub fn main() !void {
    var ev: std.Io.Uring = undefined;
    try std.Io.Uring.init(&ev, std.heap.page_allocator, .{});
    defer ev.deinit();
    const io = ev.io();
    try io.sleep(.fromMilliseconds(1), .awake);
    std.debug.print("std.Io.Uring compiles and runs\n", .{});
}
EOF
(cd "$work" && "$ZIG_DIR/zig" build-exe verify.zig -O ReleaseFast && ./verify)

if [ -w /usr/local/bin ]; then
  ln -sf "$ZIG_DIR/zig" /usr/local/bin/zig
  echo "==> linked /usr/local/bin/zig"
fi

echo "==> Zig $("$ZIG_DIR/zig" version) ready"
