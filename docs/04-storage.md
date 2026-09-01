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

**The checksum uses the hardware CRC32C instruction** (D37) where the target has it, falling
back to a table implementation elsewhere. x86-64 has had it since 2008 and it computes
this exact polynomial, so output is byte-identical and this is an optimisation rather
than a format change — segments written by either path verify under the other. It
matters because the checksum sits in the recovery path: with the table implementation it
was about half of total replay time at 1 KiB records.

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

## Store identity

One 32-byte file, `STORE`, written when the data directory is first initialised and never
rewritten:

```
offset  size  field
  0       4   magic "DSTR"
  4       2   format version
  6       2   reserved
  8       4   created_at        unix seconds
 12      16   index_hash_key    16 random bytes, CSPRNG at initialisation
 28       4   crc32c            over bytes 0..27
```

**The index hash key is store-local state, not configuration** (D43). It is baked into
every slot in the index and into every hash written to `SNAPSHOT`, so it has to be
byte-identical on every boot for the lifetime of the data. Supplying it from the
environment made a silent, unrecoverable data-loss path out of a typo: a different key
means every lookup misses, nothing errors, and tail replay cannot repair it because sealed
segments are never re-read.

It is read before the index is constructed. Three cases:

| directory | `STORE` | behaviour |
|---|---|---|
| empty | absent | generate a key, write `STORE`, `fsync`, `syncDir` |
| has segments | present, valid | adopt the persisted key |
| has segments | absent or corrupt | **refuse to start** |

Refusing beats guessing — a missing `STORE` beside live segments means an incomplete
restore, and inventing a fresh key there orphans every entry that exists.

Deliberately its own file rather than the reserved bytes in the snapshot header, because
`SNAPSHOT` is fail-soft: a damaged one returns nothing and degrades to full replay. A key
living only there would let a damaged snapshot produce a *different* key and an unreadable
store that reports success.

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

The hash is keyed with a per-store secret so hash-flooding is not a remote
denial-of-service vector. That secret lives in `STORE` (above), not in the environment.

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

The check runs **both on insert and during maintenance** (D39). Insert alone is not enough: a
shard that stops receiving writes — after a wave of expiry, say — would otherwise hold
its dead slots indefinitely. Nothing is lost when it does, since dead slots stay
reusable, but the threshold should hold regardless of traffic.

**Maintenance runs on its own thread, every 60 seconds** (D45). It sweeps expired slots,
reclaims segments, rebuilds dead-heavy shards, and snapshots when the interval has passed —
all of it blocking disk work, so it must never run on an event-loop thread. Sixty seconds
rather than every tick because the sweep is not a correctness mechanism: expiry is
authoritative at the index and checked lazily on every read, so sweeping only reclaims
memory. At 10M entries a full sweep walks over 14M slots.

One consequence worth stating, because the number looks alarming otherwise: **bytes per
live entry is only meaningful near the admission point.** A store whose entries have
mostly expired holds a table sized for its peak, so the ratio climbs arbitrarily high —
a soak ending with 3,023 live entries in a 65,536-slot table reports 434 B/entry. That
is the minimum table size showing through, not waste that accumulates.

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

Reasoning for the departures in this section: D34 (leader commit, no staging buffer)
and D35 (single write lock, visibility before durability).

**Group commit by leader, not by timer.** Records are `pwrite`n as they arrive; the
only thing that has to be batched is the `fsync`. The first writer that needs
durability takes the flush lock and performs it, and every other writer waiting at
that moment is satisfied by the same flush. Requests are acknowledged only after their
`seq` is durable.

This replaces the earlier design — a commit thread firing every 5 ms or every 1 MiB —
and is better on both axes those triggers balanced:

- **Latency.** A writer waits one `fsync` (50–200 µs on NVMe), never up to 5 ms.
- **Batching.** Writers arriving while the leader is inside `fsync` are covered by the
  next one, so throughput still amortises.

There is also nothing left for a timer to do. The triggers existed to bound how long
staged data sits unflushed, and nothing is staged: every acknowledged write has a
writer actively waiting on it, and an unacknowledged write has no durability
requirement to bound. Both constants are therefore gone rather than implemented.

**No user-space staging buffer.** Coalescing writes in user space would mostly
duplicate what the page cache already does, while adding the buffer-lifetime failure
mode that D30 showed is easy to get wrong. Durability is identical either way: a record
is durable exactly when its class has been flushed. Available later if measurement ever
justifies it.

Up to four `fsync` calls per flush instead of one, since classes are separate files. In
practice most flushes touch one or two.

**Ordering** across the four files is established by the global `seq` stamped in every
record, so recovery can reconstruct a total order regardless of file layout. Durability,
by contrast, is tracked **per class**: each class is its own file, and appends within a
class are serialised, so flush completion order matches sequence order there. That is
what lets a waiter reason about its own sequence number without tracking a completed
prefix across concurrently written classes.

### Writes are serialised; reads are not

One lock covers the whole write path. Reads take none.

The cost is close to zero — appends to a class already serialise, group commit already
shares one flush, and the per-write CPU work is an encode plus a hash — and
`05-architecture.md` measured storage at 0.03% of what a request costs end to end.
Parallelising the write path would optimise the wrong 0.03% while introducing the
hardest concurrency in the system.

It also dissolves two problems outright: same-key mutations serialise without needing
key-striped locks, and a record's tag back-pointers can be published to the chain heads
before the record is encoded without racing another writer on the same tag.

Durability waiting happens *outside* the lock, which is what lets writers pile up behind
one flush.

**Visibility precedes durability.** The index is updated when a write is *ordered*, so a
reader can briefly observe an entry that a crash would erase. Deliberate, and standard
for group commit: the guarantee is that no *acknowledged* write is lost, and an entry in
that window has not been acknowledged to anyone. Making visibility wait for `fsync`
would serialise readers behind disk latency to remove an anomaly nobody can act on.

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

At 10k writes/s averaging 1 KB, five minutes of tail is about 3 GB. **Recovery target is
under 10 seconds**, and it is a tracked regression metric.

**Measured on tmpfs: 3,000,000 records / 3,147 MiB replayed in 9.5 s — 332 MiB/s, 3.16 µs
per record.** Independently reproduced at 8.85 s / 355 MiB/s, also on tmpfs. Inside the
target, but with only 5% of margin, so the relationship behind the number matters more than
the number:

```
recovery time  ≈  (write rate × record size × snapshot interval) / 332 MiB/s
```

A 10-second budget therefore buys roughly **3.3 GB of tail** (D38). At 1 KiB records that
covers sustained write rates up to about 11k/s with the default five-minute snapshot
interval. Above that, the lever is `DOOT_SNAPSHOT_INTERVAL_S`: halving it halves the
tail and halves recovery time. The interval is what bounds recovery, not the dataset.

Two things dominate replay, and both were measured rather than assumed. Fixed cost is
~2.6 µs per record (buffered read, decode, index insert, chain-head update). Per-byte
cost is ~0.55 ns after moving to the hardware checksum below; before that it was
~2.5 ns/byte and accounted for roughly half of total replay time.

Reads during replay are buffered in 1 MiB chunks. One `pread` per record would make
recovery a syscall per record and miss the target by orders of magnitude.

**The filesystem these figures came from is part of the claim** (D48). They were measured
on tmpfs, replaying bytes already resident in memory, so `332 MiB/s` is a warm-page-cache
rate and the formula above is an optimistic bound. A cold restart reads the tail from the
deployed volume. Sequential NVMe reads should clear a 3.3 GB tail comfortably, but "should"
is weaker than every other number on this page, so **M5 must re-measure on the deployed
filesystem from a cold page cache** and that becomes the number the operational lever
derives from.

A related caution for anyone reading the harness: its write phase is single-threaded, so
every write becomes its own flush leader and pays a full `fsync` with nobody to piggyback.
On tmpfs that is ~41,000 writes/s; on a persistent volume it is ~200. That is leader commit
(D34) behaving exactly as designed under a workload with no concurrency — **the write phase
is a durability test, not a throughput measurement**, and must never be quoted as one.

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

**The ring belongs to the storage engine** (D44), published from inside the write path while
the write lock is held. Two reasons: `seq` and the location are generated there, so ring
order matches sequence order for free; and a callback out to the server would run request
code underneath the global write mutex. Reading is a cursor-based poll — the server asks for
everything after a sequence it has already seen — so the engine holds no subscriber
registry.

The ring is built in M2 with the write path. Subscriber fan-out, SSE framing and the
refcounted frame slots D30 forced are M4.

**Visibility precedes durability here too.** A subscriber can observe a mutation a crash
would erase, for the same reason a reader can (see Durability above). Consistent with the
feed being best-effort.

## Control-plane state

Accounts, API key hashes, sessions, OTP challenges, identity anchors and credit balances
must survive a restart, and none of them can live in the entry store: every entry must
expire, segment reclamation would `unlink()` them, and "never expires" is not representable
in a slot whose liveness *is* its expiry (D40).

So they live in **`CONTROL`, an append-only log with the entire state held as an in-RAM
image.** No index, no segments, no partial loading — at ten thousand accounts the whole
image is single-digit megabytes, so disk exists only to rebuild it at boot.

| property | value |
|---|---|
| mutation | append a length-prefixed, CRC32C-checksummed event, then `fsync` before responding |
| recovery | replay from the start into empty maps; a torn tail is truncated |
| reclamation | wholesale rewrite via `CONTROL.tmp` → `fsync` → `rename` → `syncDir`, once the log exceeds 8× the live image — or 8× one page, whichever is larger, since without a floor a store holding one account would rewrite on almost every mutation |
| location | `DOOT_DATA_DIR`, beside the segments — segment discovery skips filenames it does not recognise |

Signup, key creation, revocation and login are rare enough that one flush each is
invisible. Rewriting wholesale is possible precisely because the image fits in RAM, so
there is no incremental compaction problem — the same reclamation-not-compaction
distinction drawn for index shards.

**Credit balances are authoritative in RAM and checkpointed as absolute values** at the
snapshot interval, never logged per write (D41). One invariant governs the design:

> A credit deduction must never be durable unless the write it paid for is also durable.

That permits losing deductions and forbids losing entries, so an unclean restart can only
ever grant free writes — never charge for a write that did not land. Absolute values rather
than deltas keep the log from growing with write volume and stop a partial checkpoint from
compounding.

**Two things stay out of the log entirely, and both are deliberate:**

| state | why RAM only |
|---|---|
| rate-limit buckets | 16 B/account; every bucket starts full after a restart, which is the generous direction. Persisting a token count across a ten-second outage preserves a number that has already refilled |
| idempotency records | 48 B, capped at 1M, lost on restart (D42). Persisting would put an `fsync` on the path every automated caller is told to use, and would leave orphaned in-progress keys returning `409` for 24 hours after a crash |

A record holds two truncated hashes, the packed location of the record it wrote, a status
and an expiry — **not** the metadata it replays. That does not fit in 48 bytes, so a replay
re-reads the record at that location and renders the document from it (D61).

At the idempotency cap, records closest to expiry are dropped first. Because every record
gets the same 24-hour window from its own insertion, expiry order *is* insertion order, so
that rule is a write cursor that wraps rather than a priority queue (D62). **A full table
never rejects a write** — an optional header must not be able to fail a valid request, and
dropping a record degrades to re-execution, which is what omitting the header already does.

## Backup

Sealed segments are immutable, which is what makes backup nearly trivial. Target is
Cloudflare R2 (any S3-compatible endpoint works).

| object | upload policy |
|---|---|
| `STORE` | once, at initialisation, never again — immutable, and a restore without it cannot proceed |
| sealed segments | once, on seal, never again |
| index snapshots | every 5 minutes, last 3 retained |
| open segment tails | every 5 minutes, current tail bytes only |
| `CONTROL` | every 5 minutes, whole file — single-digit megabytes, so wholesale is cheaper than tracking a tail |

**Recovery point is the tail interval — 5 minutes by default**, configurable. Nothing
is ever re-uploaded except the four open tails, so bandwidth is bounded by write rate,
not by dataset size.

Cost is negligible. R2 charges nothing for egress; class-A operations run about
$4.50/million and storage about $0.015/GB/month. Backing up 50 GB with 5-minute tail
pushes is roughly **$0.75/month**, all in.

**Restore** pulls `STORE` first — without its index hash key nothing written before the
restore is addressable — then the newest snapshot plus every segment it references, then
replays the tails, then loads `CONTROL`. The same code path as local recovery, with a
different source. This must be drilled before launch, not after. An untested restore is not
a backup.

Segments whose `max_expiry` has passed are deleted from R2 too, so backup storage
tracks live data rather than growing without bound.

## Memory budget

The number this design exists to control. At 10 million live entries on a 16 GB box:

| consumer | cost | at 10M entries |
|---|---|---|
| index | 29 B/entry | 286 MB |
| tag chain heads | O(tags/account) | ~32 MB |
| idempotency records | 48 B × 1M, plus an 8 MB index into them (D62) | ~56 MB |
| in-flight request buffers | 256 concurrent × 260 KiB | 65 MB |
| control-plane image | O(accounts), ~200 B each plus keys and sessions | ~10 MB at 10k accounts |
| connection state | pooled, 0.63 KB/conn at a 512 B idle read buffer (D28) | ~1.3 MB at 2,000 |
| rate limit buckets | 16 B/account | < 1 MB |
| change feed ring | 65,536 × 24 B | 1.5 MB |
| **application total** | | **~450 MB** |
| **left to page cache** | | **~15 GB** |

The in-flight buffer slot is **260 KiB, not 256 KB** (D51). A read has to hold an entire
record, and `record.max_record_bytes` is 262,929 — a 256 KB slot is 785 bytes short, which
would truncate exactly the largest entries the product permits. 266,240 B is the next page
multiple, and 256 of them is precisely 65 MiB.

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

This table originally carried a note that at around 5M entries **idle connections cost more
RAM than stored data does**. That was true of the naive allocation it assumed — 8.1 KB per
connection, so the crossover sat near 18,000 idle connections — and D28 moved it by more
than an order of magnitude: pooled connection structs and arena-carved read buffers cost
0.63 KB each, putting the crossover past 200,000 connections. The conclusion it was drawn to
support stands unchanged and is the reason for the measurement: **buffers are pooled per
in-flight request rather than per connection** (`05-architecture.md`). The alarming version
of the claim is simply no longer accurate.

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
| group commit | leader-driven, no interval | — |
| snapshot interval | 5 minutes | `DOOT_SNAPSHOT_INTERVAL_S` |
| index slot size | 20 bytes | — |
| index max load factor | 0.70 | — |
| index shards | 64 | — |
| index rebuild threshold | 25% dead slots | — |
| tag traversal hop budget | 500 per page | — |
| tombstone lifetime | 2 × snapshot interval | derived |
| change feed ring | 65,536 events | — |
| backup tail interval | 5 minutes | `DOOT_BACKUP_INTERVAL_S` |
| recovery target | < 10 seconds | — |
| index memory ceiling | no default — **required at boot** | `DOOT_MAX_INDEX_BYTES` |
| index hash key | 16 bytes, generated once into `STORE` | **not configurable** (D43) |
| maintenance interval | 60 seconds | — |
| control log rewrite threshold | 8 × live image size | — |
| credit checkpoint interval | snapshot interval | derived |
| idempotency record cap | 1,000,000, RAM only | — |
| in-flight request buffer slot | 266,240 bytes (260 KiB) | — |

The commit interval and size trigger are deliberately absent rather than unset: leader
commit removes the need for either. See Durability.

## Deliberately absent

- **Compaction as a steady-state process.** Bounded lifetime replaces it.
- **A B-tree or LSM tree.** No range queries exist to justify ordered structure.
- **Secondary indexes beyond tag chains.** No query language to feed them.
- **Bloom filters.** The index is authoritative and in RAM; nothing to probe past.
- **Compression at rest.** Bodies are ≤ 256 KB and opaque; CPU and complexity buy
  little, and it would break the byte-identical read contract's simplest proof.
- **Replication.** Single box is the stated architecture. Off-box backup is the
  durability answer.
