# Storage engine

Canonical source for internal constants. Two constraints drive every decision here:

1. **Memory is the most expensive resource on a single box.** Not disk, not CPU.
   Every design choice is evaluated on bytes of RAM per live entry first.
2. **Mandatory bounded lifetime is an asset, not a limitation.** Because every entry
   expires and the maximum is bounded, whole regions of storage become droppable
   wholesale. Exploited properly, this eliminates compaction from the steady state.

## The central memory insight

The naive index stores the name in RAM so lookups can be resolved without touching
disk. For Doot that is wasted memory, because **every read has to touch disk
anyway** — the body lives there.

So names are not held in RAM. The index stores a 64-bit hash of
`(account_id, name)`, and the full name is verified against the record already being
read to serve the request. Verification is free. Storing names buys nothing.

Consequence: **~29 bytes of RAM per live entry**, roughly a sixth of a name-resident
index.

## Layout

Every entry lives in an append-only segment file. Segments are grouped into four
**lifetime classes** by requested lifetime, and each class has its own append stream.

| class | requested lifetime | file prefix |
|---|---|---|
| 0 | ≤ 1 hour | `c0-` |
| 1 | ≤ 24 hours | `c1-` |
| 2 | ≤ 7 days | `c2-` |
| 3 | ≤ `DOOT_MAX_TTL` | `c3-` |

Segments are fixed at **64 MiB**. A segment **seals** when full, and is immutable
forever after. Each sealed segment records the maximum `expires_at` of every record
it contains. When wall clock passes that value, every record in the file is expired
by construction and the file is `unlink()`ed.

**No compaction. No tombstone sweep. No rewrite. No background job competing with
the write path for disk bandwidth.** Reclamation is a filesystem unlink.

### Why classes, and not expiry-time partitioning

Partitioning by *expiry time* is the obvious first idea and it is wrong. A segment
holding expiries in window `[T, T+1d)` accepts writes from `T − max_ttl` all the way
to `T`, so it stays open for the entire maximum-lifetime window and is immutable only
briefly before deletion. That breaks backup (nothing is ever stable long enough to
upload once) and implies up to `max_ttl / bucket` open files.

Classes fix both. Four open files, four sequential streams, and a segment's
`max_expiry` is approximately `seal_time + class_bound` — so short-lived data
reclaims quickly and cannot be pinned by long-lived neighbours.

Classes are what make wholesale reclamation actually work. Without them, one 30-day
entry keeps 64 MiB of one-hour data alive for a month.

Class boundaries derive from `DOOT_MAX_TTL`. If the configured maximum is 7 days or
less, class 3 is not created. Nothing hardcodes 14 or 30 days.

### Residual garbage

Overwrites and deletes leave superseded records inside still-live segments. This is
bounded and self-clearing: the dead bytes are reclaimed when the segment expires,
same as everything else.

A compactor exists as an **escape hatch only** — triggered when a segment is more
than 70% dead bytes *and* has more than 24 hours of life remaining. This is a
pathological tail case, not the steady state, and it must never be on the hot path.

## Record format

Little-endian. Appended within a class segment.

```
offset  size  field
  0       4   record_length      total bytes including this header
  4       8   seq                global monotonic sequence number
 12       4   account_id
 16       4   created_at         unix seconds
 20       4   expires_at         unix seconds
 24       1   flags              bit0 tombstone, bits1-2 class, bits3-7 reserved
 25       1   name_len_m1        name length minus one: 0..255 encodes 1..256
 26       1   tag_count          0..5
 27       1   content_type_len   0..128
 28       4   body_len           0..262144
 32       4   crc32c             over bytes 0..31 and 36..record_length
 36       …   name
        …     content_type
        …     tags: per tag → 1 byte length, tag bytes, 8 byte prev_chain_ptr
        …     body
```

**Name length is stored biased by one.** Names are 1–256 bytes (`03-data-model.md`) and
can never be empty, so `0..255` maps exactly onto `1..256`. This keeps the field one byte
wide while matching the documented limit; an unbiased byte would silently cap names at
255 and contradict the data model.

**The checksum covers the header, not just the payload.** Everything except the four
`crc32c` bytes themselves is protected. Covering only the payload would leave
`record_length` and `body_len` unverified, and those two fields are what a recovery scan
uses to find the next record — a single corrupted length byte would walk the scanner into
garbage with nothing to detect it. The framing must be as trustworthy as the contents.

`prev_chain_ptr` per tag is the on-disk tag traversal chain; see below.

### Verifying a record

`record_length` cannot be trusted before the checksum is verified, and the checksum
cannot be computed without knowing how many bytes to read. So verification is ordered:

1. Read the fixed 36-byte header.
2. Bounds-check `record_length` against the minimum possible record and the maximum
   (header + 256-byte name + 128-byte content type + 5 tags + 256 KB body). A value
   outside that range is rejected without ever being used as a length.
3. Read the remainder and verify `crc32c`.

**The same failure means different things in different places, and both are correct:**

| where | meaning | response |
|---|---|---|
| tail scan during recovery | a torn write at the moment of the crash | stop the scan; this record and everything after it never existed |
| read of an already-indexed record | corruption of data that was once durable | serve `404`, count and log it; never a partial or wrong body |

A torn tail is expected — it is what a crash mid-append looks like. Corruption of a
record the index still points to is not, which is why the two are counted separately.

## Locations

A record is addressed by a packed 64-bit location:

| bits | width | field | capacity |
|---|---|---|---|
| 0–25 | 26 | offset within segment | 64 MiB |
| 26–49 | 24 | segment id, monotonic, never reused | 16.7M segments ≈ 1 PiB written cumulatively |
| 50–51 | 2 | lifetime class | 4 |
| 52–63 | 12 | reserved | |

Segment ids are never recycled, which keeps locations globally unambiguous and makes
stale references safely detectable rather than silently wrong. At 24 bits the id
space outlasts any plausible lifetime of a single box.

## The index

An open-addressed hash table. **20 bytes per slot**, maximum load factor 0.70, so
**~29 bytes per live entry**.

| offset | size | field |
|---|---|---|
| 0 | 8 | hash of `(account_id, name)` — SipHash-1-3, keyed with a per-instance secret |
| 8 | 8 | packed location |
| 16 | 4 | `expires_at`, unix seconds |

`expires_at` is duplicated into the slot specifically so expiry can be decided
without a disk read — the overwhelmingly common negative case (`404` on an expired
entry) costs no I/O at all.

**Lookup:** hash `(account_id, name)` → probe → read the record at the location →
compare the stored name to the requested name. On mismatch, continue probing. Since
colliding names share a probe sequence, continuing is correct. The verifying disk
read is the same read that fetches the body, so collision handling is free.

The hash is keyed with a per-instance secret so hash-flooding is not a remote
denial-of-service vector.

**Sharding:** 64 shards selected by the top bits of the hash, each with its own lock.
This serves three purposes at once — write concurrency across cores, bounded lock
hold times, and consistent shard-at-a-time snapshots (below).

### Slot lifecycle: expiry and deletion are the same thing

Open addressing cannot simply blank a slot. Doing so severs the probe sequence, and
every entry stored past the hole becomes unreachable. Removal has to leave something
behind that probes still traverse.

Doot needs no separate marker for this, because **a slot already carries `expires_at`,
and a dead slot is exactly one whose `expires_at` has passed:**

| state | `expires_at` | lookup | insert |
|---|---|---|---|
| live | in the future | returns it | must not overwrite |
| expired | in the past | skips it, keeps probing | may reuse in place |
| deleted | forced to `0` | skips it, keeps probing | may reuse in place |

Deletion sets `expires_at = 0` — a value permanently in the past — and clears the
location. So deleted and expired slots are indistinguishable to every code path, which
is the correct outcome: `03-data-model.md` requires that expired and absent entries be
indistinguishable to callers, and this makes that true in the data structure rather than
in a check layered on top.

This also makes **segment reclamation safe for free.** A segment is only unlinked once
every record in it has expired, so any slot still pointing into it necessarily has
`expires_at` in the past and is already treated as absent. No index scan is needed at
unlink time, and a lookup can never be handed a location in a file that no longer
exists.

### Rebuild, not compaction

Dead slots stay probe-transparent until reused, so a shard's *occupancy* — live plus
dead — is what governs probe length, while only the live count matters to the memory
budget. Those diverge over time under overwrite and delete traffic.

A shard is therefore **rebuilt** when dead slots exceed 25% of its capacity: reinsert
the live entries into a fresh table, discard the dead, swap under the shard lock. This
is bounded per shard, off the request path, and unrelated to segment compaction — it
reclaims index memory, never touches disk, and is a normal steady-state event rather
than the escape hatch that segment compaction is.

Admission control (below) measures occupancy, because that is what actually runs out.

## Tag traversal

A posting list per tag would cost `O(entries)` RAM, which would dwarf the index and
undo the memory work. So the lists live on disk.

Each record carries, per tag, a `prev_chain_ptr` to the previous record written with
that same tag in that same lifetime class. RAM holds only the **chain heads**:

```
(account_id, tag, class) → location of the most recent record
```

**In-memory tag cost is `O(distinct tags per account)`, not `O(entries)`.** At 10k
accounts averaging 50 tags each, that is roughly 32 MB — permanently negligible, and
independent of how much data is stored.

**Why chains are per class, not per tag.** Chains are ordered by write time, but
entries expire in a different order. A chain crossing classes could contain a dead
link whose segment is already unlinked, orphaning live entries behind it. Within a
single class, expiry order and write order agree, so once traversal reaches a dead
link everything beyond it is dead too, and stopping is correct. Cost is four head
pointers per tag instead of one.

**Listing** merges the (up to four) class chains newest-first by `seq`. Each hop is
validated against the index: hash the record's name, probe, and confirm the live
location matches this record. This skips superseded and deleted records, which is
required for correctness after any overwrite or delete.

**Traversal is bounded** at 500 hops per page. A page that exhausts the hop budget
returns early with a cursor. This is why a short page does not imply the end of the
result set, and why clients must paginate until the cursor is absent. The bound is
what keeps a free operation from becoming an unbounded disk scan.

## Durability

**Group commit.** Writers stage records into a per-class buffer. A commit thread
flushes and `fsync`s every **5 ms**, or immediately when a buffer crosses 1 MiB.
Requests are acknowledged only after their `seq` is durable.

Up to 5 ms of added write latency is invisible: a request from a distant client costs
around 175 ms end to end (`05-architecture.md`), so commit latency is under 3% of what
the user experiences. Optimising it further would be measuring the wrong thing.

Up to four `fsync` calls per commit window instead of one, since classes are separate
files. On NVMe each is 50–200 µs, and in practice most windows touch one or two
classes. Accepted, and worth re-measuring under real load.

**Ordering** across the four files is established by the global `seq` stamped in every
record, so recovery can reconstruct a total order regardless of file layout.

## Snapshots and recovery

The index is snapshotted to disk every **5 minutes**. The snapshot is the packed slot
array itself, so it is `mmap`-able and loads without deserialisation.

```
snapshot header
  magic, format version
  seq watermark
  per-class open segment id + offset
  shard count, slot count, load factor
  crc32c of the slot array
```

**Recovery:** `mmap` the snapshot, then scan each class's open segment forward from
the recorded offset, applying records in `seq` order. Later `seq` wins. Recovery never
re-reads sealed segments and never scans the full dataset.

At 10k writes/s averaging 1 KB, five minutes of tail is about 3 GB, scanned in a
couple of seconds on NVMe. **Recovery target is under 10 seconds**, and it is a
tracked regression metric.

**Snapshots are taken shard by shard**, each under its short-lived shard lock, so no
slot is ever copied mid-update and no global stop-the-world is needed. Writes landing
during the snapshot are corrected by tail replay, which is idempotent.

### Tombstones are almost free

Because recovery only replays records *after* the snapshot watermark, a tombstone only
needs to survive long enough to be captured by the next snapshot. Deletes are written
to class 0 with `expires_at = now + 10 minutes` — twice the snapshot interval.

This removes an entire category of garbage-collection problem: there are no
long-lived tombstones to track, and no risk of a deleted entry resurrecting because
its tombstone was reclaimed first.

## Change feed

The `seq` stream is already a totally ordered log of every mutation, so the dashboard's
live view needs no separate mechanism. An in-memory ring buffer holds the most recent
**65,536** events as `(seq, account_id, location, op)` — 24 bytes each, about 1.5 MB
total.

SSE subscribers filter by `account_id`. A subscriber that falls behind the ring is
sent a resync marker rather than being silently skipped. The feed is best-effort by
design; it drives a UI, not a guarantee.

## Backup

Sealed segments are immutable, which is what makes backup nearly trivial. Target is
Cloudflare R2 (any S3-compatible endpoint works).

| object | upload policy |
|---|---|
| sealed segments | once, on seal, never again |
| index snapshots | every 5 minutes, last 3 retained |
| open segment tails | every 5 minutes, current tail bytes only |

**Recovery point is the tail interval — 5 minutes by default**, configurable. Nothing
is ever re-uploaded except the four open tails, so bandwidth is bounded by write rate,
not by dataset size.

Cost is negligible. R2 charges nothing for egress; class-A operations run about
$4.50/million and storage about $0.015/GB/month. Backing up 50 GB with 5-minute tail
pushes is roughly **$0.75/month**, all in.

**Restore** pulls the newest snapshot plus every segment it references, then replays
the tails — the same code path as local recovery, with a different source. This must
be drilled before launch, not after. An untested restore is not a backup.

Segments whose `max_expiry` has passed are deleted from R2 too, so backup storage
tracks live data rather than growing without bound.

## Memory budget

The number this design exists to control. At 10 million live entries on a 16 GB box:

| consumer | cost | at 10M entries |
|---|---|---|
| index | 29 B/entry | 286 MB |
| tag chain heads | O(tags/account) | ~32 MB |
| idempotency records | ~50 B, capped at 1M | ≤ 50 MB |
| in-flight request buffers | 256 concurrent × 256 KB | 64 MB |
| connection state | ~8 KB × 2,000 | 16 MB |
| rate limit buckets | 16 B/account | < 1 MB |
| change feed ring | 65,536 × 24 B | 1.5 MB |
| **application total** | | **~450 MB** |
| **left to page cache** | | **~15 GB** |

Roughly **97% of RAM is left to the kernel page cache**, which is exactly right —
that is where hot bodies belong.

**There is no application-level body cache.** The page cache already holds hot entries
and a user-space cache would buy the same memory a second time. This is a decision,
not an omission.

Scaling of the index alone:

| live entries | index RAM |
|---|---|
| 1M | 29 MB |
| 10M | 286 MB |
| 100M | 2.9 GB |

Note what this implies at modest scale: at around 5M entries, **idle connections cost
more RAM than stored data does**. Buffers are therefore pooled per in-flight request
rather than per connection (`05-architecture.md`).

## Capacity ceiling and admission control

The box must degrade predictably, never crash. `DOOT_MAX_INDEX_BYTES` sets a hard
ceiling.

| index utilisation | behaviour |
|---|---|
| < 85% | normal |
| ≥ 85% | warning logged, surfaced in `/admin/stats`, operator alerted |
| ≥ 100% | **new** entries rejected with `503 capacity_exhausted` |

Overwrites of existing entries continue to be accepted at 100%, since they reuse a
slot and add no index pressure. Reads, lists and deletes are unaffected — deletes
especially, since deleting is how a user recovers from this state.

Disk is monitored on the same pattern, at 85% and 95% of the configured volume.

## Testability is a structural requirement

Almost everything above is a function of two things the engine does not control: **what
time it is** and **when the machine dies**. Neither can be observed usefully if they are
reached for directly, so both are injected.

### The clock is a parameter

Every expiry decision, segment reclamation, tombstone lifetime and snapshot interval
derives from a single injected clock rather than a direct system call.

This is not test scaffolding. The engine's central claim is that bounded lifetime
eliminates compaction, and that claim is about behaviour over **days** — a 24-hour
mixed-lifetime soak is one of M1's exit conditions. With a wall clock, verifying it
takes 24 hours and cannot be run in CI, so in practice it never gets run and the
central claim stays unverified. With an injected clock it runs in seconds, on every
change.

Two implementations: the real clock, and a manual one that only advances when told.
Nothing else in the engine may read the system time.

### The crash point is a parameter

Durability is defined by what survives a crash at the worst possible moment, and the
worst possible moments are the `fsync` boundaries. So `fsync` calls are counted, and a
build can be told to abort immediately after the *n*-th one.

That converts "does it survive a crash" from a question answered by argument into one
answered by enumeration: run the same workload once per boundary, kill it at that
boundary, reopen, and check the invariants. M1's crash-injection exit condition depends
on this hook existing.

The counter is always compiled in — it is one increment on a path that already performs
a syscall costing 50–200 µs, so it is free — but the abort is only armed by explicit
configuration and can never trigger in production.

### What the seams must guarantee

- **No acknowledged write is ever lost.** A write acknowledged before the crash is
  present after recovery.
- **Nothing resurrects.** A deleted or expired entry never reappears, at any crash
  point.
- **Recovery is idempotent.** Replaying the same tail twice yields the same state, so a
  crash *during* recovery is survivable too.

## Constants

| constant | value | env override |
|---|---|---|
| segment size | 64 MiB | `DOOT_SEGMENT_BYTES` |
| lifetime classes | 1h / 24h / 7d / max | derived |
| max lifetime | 14d trial, 30d paid | `DOOT_MAX_TTL` |
| group commit interval | 5 ms | `DOOT_COMMIT_INTERVAL_MS` |
| group commit size trigger | 1 MiB | — |
| snapshot interval | 5 minutes | `DOOT_SNAPSHOT_INTERVAL_S` |
| index slot size | 20 bytes | — |
| index max load factor | 0.70 | — |
| index shards | 64 | — |
| tag traversal hop budget | 500 per page | — |
| change feed ring | 65,536 events | — |
| backup tail interval | 5 minutes | `DOOT_BACKUP_INTERVAL_S` |
| recovery target | < 10 seconds | — |

## Deliberately absent

- **Compaction as a steady-state process.** Bounded lifetime replaces it.
- **A B-tree or LSM tree.** No range queries exist to justify ordered structure.
- **Secondary indexes beyond tag chains.** No query language to feed them.
- **Bloom filters.** The index is authoritative and in RAM; nothing to probe past.
- **Compression at rest.** Bodies are ≤ 256 KB and opaque; CPU and complexity buy
  little, and it would break the byte-identical read contract's simplest proof.
- **Replication.** Single box is the stated architecture. Off-box backup is the
  durability answer.
