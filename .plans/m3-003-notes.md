# libpdx-argv.M3-003 — implementation notes

**Issue:** #8 — `--schema` prints the tool's declared output schemas.
**Upstream doc:** `design/tooling/r49-r50-plan.md` §5.12 (paideia-os).

## What landed

- `src/schema_emit.pdx` — new `SchemaEmit` module. Public surface:
  - `SchemaEmit::SCHEMA_MAX : u64 = 8` — bootstrap-scope cap
    (observed max is `pkg`'s 3 output schemas; 8 leaves ~2.5×
    headroom).
  - `SchemaEmit::reset()` — clear the table (leaf; zeroes
    schema_count).
  - `SchemaEmit::register(name_ptr)` — append at slot
    `schema_count`; silently drops past SCHEMA_MAX (mirrors
    FlagSpec::register).
  - `SchemaEmit::get_count() -> u64` — read for iteration.
  - `SchemaEmit::get_name(idx) -> u64` — per-slot NUL-terminated
    pointer, or 0 if `idx >= schema_count`.
- `design/architecture.md` §10.3 — the "storage-only, not I/O" split
  rationale and the consumer pattern that walks
  `get_count`/`get_name` and writes each name via the consumer's own
  stdout cap.
- `STATUS.md` — the M3 consumer wiring block includes the `--schema`
  branch after the `--help` branch.

## Design decisions

- **Storage-only, not I/O.** libpdx-argv holds no capability (see
  `caps.decl`: "libpdx-argv requires no caps of its own"). SchemaEmit
  owns the table of registered schema names; the actual write to
  stdout is the consumer's responsibility (which holds the KIND_TTY
  / KIND_IPC_ENDPOINT cap for stdout). This split lets libpdx-argv
  land at M3 without waiting for R42 (PdxFS / stdout syscall
  substrate).
- **FlagSpec-shaped API.** `reset` / `register` / `get_count` /
  `get_name` mirrors FlagSpec's storage-then-lookup shape so a
  consumer that already understands FlagSpec finds SchemaEmit
  familiar. The one extra call (`get_name` vs FlagSpec's inline
  `spec_names[i]` walk in lookup) is because SchemaEmit's caller
  wants to iterate all slots, not search by key.
- **SCHEMA_MAX = 8.** Every P0 tool's observed maximum is 3
  (`pkg`: PackageManifest[], InstallProgressRecord[],
  KeyFingerprintRecord[]). 8 leaves headroom for M4+ additions
  without inflating .bss (64 B for the array + 8 B for the count).
- **Pointers stored raw; SchemaEmit never dereferences them.** The
  table entries are pure u64 pointer values; the consumer supplies
  NUL-terminated .rodata addresses. This keeps SchemaEmit's fault
  surface at zero — a bad pointer only fails at the consumer's
  eventual write, not at library ingest time.
- **`get_name` returns 0 on out-of-range.** Consistent with
  FlagSpec::lookup's miss convention (returns 0 for the id) and
  with ParsedArgs::find_flag_by_id's MAX_FLAGS sentinel. Callers
  reading past `get_count()` see a stable 0 rather than a random
  .bss byte.

## paideia-as conformance

- Module `SchemaEmit` (PascalCase basename).
- All entry points are leaf (no push/pop parity needed).
- No `test` mnemonic; every zero-check via `cmp reg, 0`.
- Every `cmp reg, imm` ≤ 0x7FFFFFFF (max: 8 = SCHEMA_MAX).
  Bounds check in `get_name` uses reg-reg compare after loading
  schema_count.
- `r11` used only for `lea r11, [rip + xxx]` cross-module .bss
  bases; never live across a call.
- No byte loads (all reads/writes are qword-wide pointer values);
  #1248 mitigation not applicable.

## Cross-module linkage

None. SchemaEmit's .bss is entirely self-owned (`schema_names`,
`schema_count`). The consumer's dispatch pattern uses
`ParsedArgs::find_flag_by_id(StdVocab::STD_ID_SCHEMA)` to detect the
flag — that's a `ParsedArgs`+`StdVocab` couplement the consumer
already holds from M2.

## What did not land (queued for M4+)

- Runtime parse of `caps.decl` `declares_output_schemas:` — the
  consumer bakes its schema list into .rodata and registers them by
  pointer at `_start`. Runtime caps.decl parsing is post-M5 (gated
  on the `pdx-help` library).
- Newline/JSON emission format helpers — SchemaEmit hands back raw
  NUL-terminated bytestrings; the consumer decides whether to write
  them one-per-line, JSON-arrayed, or in another format. Once
  libpdx-semantic-pipe M2 lands, a helper could emit each name as a
  typed record on the tool's --schema output pipe; that's an M4+
  concern gated on the semantic-pipe substrate.
- Schema-fingerprint (BLAKE3-truncated hash) alongside the name —
  the M3 shape stores only the human-readable name string. A future
  addition could store a `(name_ptr, hash_ptr)` pair per slot; that
  lands with libpdx-semantic-pipe M3.
