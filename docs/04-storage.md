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
 25       1   name_len           1..255
 26       1   tag_count          0..5
 27       1   content_type_len   0..128
 28       4   body_len           0..262144
 32       4   crc32c             over all bytes after this field
 36       …   name
        …     content_type
        …     tags: per tag → 1 byte length, tag bytes, 8 byte prev_chain_ptr
        …     body
```

`crc32c` is verified on read. A failed check is served as `404` with the corruption
counted and logged, never as a partial or wrong body.

`prev_chain_ptr` per tag is the on-disk tag traversal chain; see below.

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
