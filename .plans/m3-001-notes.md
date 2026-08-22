# libpdx-argv.M3-001 — implementation notes

**Issue:** #6 — alternate invocation: typed schema record → ParsedArgs.
**Upstream doc:** `design/tooling/r49-r50-plan.md` §5.12 (paideia-os).

## What landed

- `src/schema_invoke.pdx` — new `SchemaInvoke` module. One entry
  point:
  - `SchemaInvoke::parse_from_schema_record(record_ptr, record_len)
    -> u64` — reads a v1 typed record and populates the same
    ParsedArgs singleton the argv path fills. Consults
    `FlagSpec::lookup(name)` per stored flag so `flag_ids` /
    `flag_kinds` are populated identically to `Parser::parse_argv`.
  - Public wire-form constants: `SCHEMA_HEADER_SIZE = 32`,
    `SCHEMA_FLAG_STRIDE = 16`, `SCHEMA_POS_STRIDE = 8`,
    `SCHEMA_VERSION_V1 = 1`.
- `src/parsed_args.pdx` — three new error codes:
  - `ERR_SCHEMA_BAD_MAGIC = 7`
  - `ERR_SCHEMA_UNSUPPORTED_VERSION = 8`
  - `ERR_SCHEMA_BAD_LAYOUT = 9`
  Codes share the same space as `Parser::parse_argv`'s errors so a
  consumer's error-dispatch table is invocation-path agnostic.
- `caps.decl` — added `PdxArgvRecord@0.1` to the declared output
  schemas (alongside the M1 `PdxArgvParsed@0.1`).
- `design/architecture.md` §10.1 — full wire-form spec table,
  semantics, precondition list, and the "what M3-001 does not
  validate" note (string-terminator + tail bounds are M4 test-matrix
  concerns).

## Design decisions

- **Wire form is 8-byte-aligned throughout.** Every field is u64 or
  a 16-byte flag entry (two u64s). This lets `mov rax, [ptr + imm8]`
  loads work at every access without narrow-load mnemonics; the M1
  `mov_b` #1248 mitigation applies only to the magic-check bytes.
- **Magic is 8 byte-compares, not a qword load.** `"PDXARGV\0"` as
  a u64 exceeds 0x7FFFFFFF, so a `cmp rax, imm64` would violate the
  paideia-as constraint. The 8-cmp pattern is the M1 --pdx-schema
  precedent (parser.pdx tail) — proven safe on paideia-as ≥ v0.33.
- **Interior pointers, not copies.** ParsedArgs entries are
  `record_ptr + offset`; the caller borrows the record buffer to
  libpdx-argv for the ParsedArgs lifetime, exactly the way argv is
  borrowed. No allocation, no copy.
- **FlagSpec::lookup is called per stored flag.** This is the load-
  bearing "converges on same ParsedArgs" behaviour: a consumer's
  `find_flag_by_id` dispatch works whether the tool was reached via
  a shell command line or via a semantic-pipe frame from another
  tool that already knew the callee's `--schema` shape.
- **Body-fits bound check.** `record_len >= 32 + flag_count*16 +
  pos_count*8` is verified once at the head, so the per-entry loads
  are guaranteed in-bounds. String-table bounds (offsets pointing at
  well-terminated strings inside the record) are trusted at M3-001
  and re-visited at M4-001's test matrix.
- **`ddash_seen` / `emit_schema` untouched.** The schema record has
  no literal `--` sentinel and no `--pdx-schema` well-known flag; a
  sender expressing either concept does so via a registered flag id.
  Leaving both ParsedArgs slots at their reset() value keeps the
  M2 consumer semantics intact.
- **Prologue mirrors `Parser::parse_argv` exactly.** 6-push +
  `sub rsp, 8` = 7 slots on stack after ret addr → `rsp % 16 = 0`
  at every nested `call FlagSpec::lookup`. Callee-save assignments
  parallel Parser: rbx = record_ptr (was argv), r12 = record_len
  (was argc), r13 = i, r14 = value_ptr, r15 = id, rbp = name_ptr.

## paideia-as conformance

- Module `SchemaInvoke` (PascalCase basename).
- No `test` mnemonic; every zero-check via `cmp reg, 0`.
- Every `cmp reg, imm` ≤ 0x7FFFFFFF (max: 32 for MAX_FLAGS/MAX_POS;
  single-byte ASCII 0x00..0xFF for magic-byte checks). Version and
  record-length compares use reg-reg after loading the value.
- `r11` used only for `lea r11, [rip + xxx]` cross-module .bss
  bases; never live across a call.
- Every byte load is `xor rax, rax; mov_b rax, [ptr]` (#1248).
- SysV push/pop parity: 6 pushes (rbx/rbp/r12/r13/r14/r15) + sub
  rsp, 8 in prologue; add rsp, 8 + 6 pops in epilogue. Both epilogue
  arms (schema_ok fall-through and schema_fail fall-through) reach
  the same single epilogue.

## Cross-module linkage

Reads/writes across `ParsedArgs`: `flag_names`, `flag_values`,
`flag_count`, `pos_ptrs`, `pos_count`, `error_code`,
`error_arg_index`, `flag_ids`, `flag_kinds`. Calls
`FlagSpec::lookup` by qualified name. Same cross-module vocabulary
`Parser::parse_argv` established at M2-001.

## What did not land (queued for M4+)

- Per-string-terminator validation on the schema record — M4-001
  test-matrix line ("typed-arg-parse-error diagnostics" is the
  closest anchor).
- Wire-form v2 (per-flag `kind` override, compound `flag_group`) —
  post-M5 concern; would require a coordinated schema-fingerprint
  bump with libpdx-semantic-pipe.
- Runtime schema-hash prefix validation. libpdx-semantic-pipe's
  M2 envelope layer strips the 32-byte BLAKE3-truncated hash before
  handing the record body to `parse_from_schema_record`; libpdx-argv
  itself never sees the hash.
