# libpdx-argv

paideia-os shared library: CLI argument parsing (text CLI + semantic-schema invocation)

## Purpose

Every PaideiaOS user tool has to answer the same question before it can do
any work: *what was I asked to do?* `libpdx-argv` owns that question. It
turns an invocation into a single in-memory record — `ParsedArgs` — holding
the flags seen (name, value, kind, caller-chosen id), the positional
arguments, and an error code. Flags are *declared* rather than
pattern-matched: a tool calls `FlagSpec::register(name, kind, id)` up front,
so the parser knows whether `--out` consumes the next argv slot and the tool
dispatches on a numeric id instead of re-comparing strings. The I3 nine-flag
standard vocabulary (`--help`, `--version`, `--dry-run`, `--json`,
`--schema`, `--verbose`, `--quiet`, `--color=`, `--no-cap:`) ships
pre-declared as `StdVocab::register_all()`.

The library is dual-mode by design. A tool can be invoked as text — the
classic `argv`/`argc` path through `Parser::parse_argv` — or handed a typed
`PdxArgvRecord@0.1` wire record through a semantic pipe, parsed by
`SchemaInvoke::parse_from_schema_record`. Both paths converge on the *same*
`ParsedArgs` singleton with `flag_ids` and `flag_kinds` populated
identically, so a tool's body never learns which one fed it: a peer tool
that already knows the callee's `--schema` shape skips text tokenization
entirely, and nothing downstream changes. `libpdx-argv` performs no syscalls
and declares **no capabilities of its own** (`caps.decl`: `requires:
(none)`); it reads the caller's argv memory and, for the `--foo=bar` form,
null-terminates in place on the separator.

## API surface

All functions carry `!{mem} @{}` — memory effect only, zero capabilities.
Several return two values in the SysV `rax:rdx` pair, noted per entry;
callers must treat `rdx` as clobbered across those calls.

### parsed_args.pdx — `ParsedArgs`

The record itself: `flag_names`/`flag_values`/`flag_ids`/`flag_kinds`
(`[u64; 32]` each) + `flag_count`, `pos_ptrs`/`pos_count`, `error_code`,
`error_arg_index`, `emit_schema`, `ddash_seen`, `ddash_arg_index`.
`MAX_FLAGS = MAX_POS = 32`. Error constants: `ERR_OK` 0,
`ERR_FLAG_OVERFLOW` 1, `ERR_POS_OVERFLOW` 2, `ERR_UNKNOWN_ARG_FORM` 3
(empty `""` or bare `-`; `libpdx-argv.ENH-026`), `ERR_CLUSTERED_SHORT` 4,
`ERR_LONG_MISSING_NAME` 5,
`ERR_MISSING_VALUE` 6, `ERR_SCHEMA_BAD_MAGIC` 7,
`ERR_SCHEMA_UNSUPPORTED_VERSION` 8, `ERR_SCHEMA_BAD_LAYOUT` 9,
`ERR_SCHEMA_BAD_OFFSET` 10, `ERR_SCHEMA_UNTERMINATED` 11,
`ERR_UNKNOWN_FLAG` 12 (opt-in strict mode only — see `FlagSpec::set_strict`),
`ERR_VERSION_EMITTED` 13 (library-owned `--version` auto-emit fired —
success signal, not an error; see `VersionBackend` below),
`ERR_INT_RANGE` 14 (INT-flag value fell outside the registered
`[min, max]` interval; set by `Typed::parse_int_u64_ranged` — see
`register_int` in `FlagSpec` and `parse_int_u64_ranged` in `Typed`
below; `libpdx-argv.ENH-018`),
`ERR_HELP_EMITTED` 15 (library-owned `--help` auto-table fallback
fired — success signal, not an error; see `HelpBackend` below;
`libpdx-argv.ENH-014`),
`ERR_CLUSTER_WITH_ARITY` 16 (`libpdx-argv.ENH-013`, Closes #23 — a
short-flag cluster `-abc` contained at least one letter whose
`FlagSpec::lookup` returned a value-consuming kind; no letter is
dispatched, `flag_count` unchanged from cluster entry. Replaces the
now-unreachable `ERR_CLUSTERED_SHORT` for the specific case that
motivates the D3 one-per-hyphen rule. `-vv`/`-abc` clusters of
BOOL/COUNTED short flags are now expanded instead of rejected).

| Function | Purpose |
| --- | --- |
| `parsed_args_reset() -> () !{mem} @{}` | Zero the bookkeeping slots so the next parse starts clean. Arrays are consumed by index, so only counters are cleared. **(Renamed from `reset` in `libpdx-argv.ENH-030`, v1.1.0.)** |
| `find_flag_by_id(id: u64) -> u64 !{mem} @{}` | Linear scan of `flag_ids`; returns the storage index `k`, or `32` (`MAX_FLAGS`) if that id was never seen. **First-wins** on a repeated flag (`libpdx-argv.ENH-008`). |
| `find_last_flag_by_id(id: u64) -> u64 !{mem} @{}` | **(ENH-008)** Same as above but **last-wins** — scans downward, so a later occurrence of a repeated flag shadows an earlier one (e.g. `--color=auto --color=never` → `never`). |
| `count_flag_by_id(id: u64) -> u64 !{mem} @{}` | **(ENH-008)** Number of stored flags with the given id (0 if never seen) — for the repeat-count idiom (`-v -v -v`). |

### flag_spec.pdx — `FlagSpec`

Declarative flag table, capacity `SPEC_MAX = 32`. Value kinds:
`FKIND_BOOL` 0, `FKIND_STR` 1, `FKIND_INT` 2, `FKIND_TIMESPAN` 3,
`FKIND_SIZE` 4, `FKIND_ENUM` 5, and the miss sentinel `FKIND_UNKNOWN` `0xFF`.

| Function | Purpose |
| --- | --- |
| `flag_spec_reset() -> () !{mem} @{}` | Clear the registration table (zeroes `spec_count`). **(Renamed from `reset` in `libpdx-argv.ENH-030`, v1.1.0.)** |
| `flag_spec_register(name_ptr: u64, kind: u64, id: u64) -> () !{mem} @{}` | Append one `(name, kind, id)` triple. Silently no-ops past `SPEC_MAX`. The flag may take its value inline (`=`/`:`) or via lookahead (`argv[i+1]`). **(Renamed from `register` in `libpdx-argv.ENH-030`, v1.1.0.)** **(`libpdx-argv.ENH-014`, Closes #24)** Now a thin wrapper over `register_with_help` that passes `help_ptr = 0`; every call site sees zero ABI change but the registration lands in the same table as help-populated entries. |
| `register_with_help(name_ptr: u64, kind: u64, id: u64, help_ptr: u64) -> () !{mem} @{}` | **(`libpdx-argv.ENH-014`, Closes #24)** The full-shape registration path: same as `flag_spec_register` plus a NUL-terminated help-text pointer published into a new `spec_help[slot]` array. A `help_ptr = 0` slot is silently suppressed from the `HelpBackend::emit_from_argspec` auto-table walk — a tool that populates ONLY some help slots gets ONLY those lines. |
| `register_sep(name_ptr: u64, kind: u64, id: u64) -> () !{mem} @{}` | **(`libpdx-argv.ENH-010`)** Same as `flag_spec_register`, but the flag's value MUST arrive inline — the parser never accepts a lookahead value for it, even if `argv[i+1]` looks like a plausible one. Use for a flag whose I3 spelling mandates a separator (`--color=`, `--no-cap:`). |
| `register_int(name_ptr: u64, id: u64, min: u64, max: u64) -> () !{mem} @{}` | **(`libpdx-argv.ENH-018`, Closes #28)** Register an INT-kinded flag (kind fixed to `FKIND_INT`) with an inclusive unsigned `[min, max]` interval published into new `spec_min` / `spec_max` slots. `Typed::parse_int_u64_ranged` reads the pair (either forwarded by the consumer or recovered via `get_range_by_id`) and rejects a decoded value outside the interval with `ERR_INT_RANGE`. Sentinel: `(min = 0, max = 0)` means "range OFF" — the plain `flag_spec_register` path writes exactly this, so every existing INT registration is transparent to the gate. |
| `get_range_by_id(id: u64) -> u64 !{mem} @{}` | **(`libpdx-argv.ENH-018`, Closes #28)** Multi-return `(min in rax, max in rdx)` — companion accessor for the range slots `register_int` publishes. Returns `(0, 0)` both for an unregistered id AND for a flag registered without a range — indistinguishable at this API, by design; callers that need to tell them apart call `lookup()` first. |
| `lookup(name_ptr: u64) -> u64 !{mem} @{}` | Inline-strcmp scan; returns **kind in `rax`, id in `rdx`**. Miss yields `FKIND_UNKNOWN` / id 0 — unregistered flags are treated as boolean. |
| `set_strict(on: u64) -> () !{mem} @{}` | **(`libpdx-argv.ENH-004`)** Opt into strict mode: `on != 0` makes both `parse_argv` and `parse_from_schema_record` fail with `ERR_UNKNOWN_FLAG` (12) on any `lookup` miss instead of storing the flag as boolean. Defaults to 0 (permissive); `flag_spec_reset()` restores 0. |

### parser.pdx — `Parser`

| Function | Purpose |
| --- | --- |
| `parse_argv(argv: u64, argc: u64) -> u64 !{mem} @{}` | The text-CLI entry point. Walks `argv`, classifies each slot, fills `ParsedArgs`, returns `ERR_OK` or an `ERR_*` code (also recorded with the offending index in `error_arg_index`). Treats `argv[0]` as an ordinary argv slot — callers invoked from `_start` should either pre-skip the program-name slot themselves or call `parse_argv_skipping_zero` (see next row). |
| `parse_argv_skipping_zero(argv: u64, argc: u64) -> u64 !{mem} @{}` | **(`libpdx-argv.ENH-031`)** Thin wrapper: advances `argv` by one pointer slot and decrements `argc` by 1 before invoking `parse_argv`, so a consumer that received `(argv, argc)` at `_start` per the frozen `execve` ABI (`design/user/execve-abi.md`) can hand them through unmodified without the program name landing in `pos_ptrs[0]`. `argc == 0` short-circuits to `parse_argv(argv, 0)`, which returns `ERR_OK` immediately without dereferencing `argv`. Every satellite `_start` consumer (`pkg`, `ls`, `cp`, `mkdir`, `mv`, `rm`, `mkfs.pdxfs`, `mount.pdxfs`, `umount.pdxfs`) wants this shape; the bare `parse_argv` remains the lower-level primitive for callers that have already pre-skipped or synthesised argv themselves. |

Grammar: long flags `--foo`, `--foo=bar`, `--foo:bar`, `--foo bar`; short
flags one letter per hyphen (`-f`), with **BOOL/COUNTED clusters expanded**
per `libpdx-argv.ENH-013` (Closes #23) — `-vv` and `-abc` where every
letter's `FlagSpec::lookup` returns `FKIND_BOOL` (or, permissive-mode,
`FKIND_UNKNOWN`) are dispatched as N independent short-flag stores; a
cluster containing any value-consuming registration fails with
`ERR_CLUSTER_WITH_ARITY` (16) BEFORE any letter is stored (no partial
dispatch). Strict mode (ENH-004) still fails an unregistered letter
with `ERR_UNKNOWN_FLAG` (12). A bare `-` is positional; `--` is a
sentinel after which every remaining argument is positional regardless
of leading byte.
Arity comes from `FlagSpec::lookup`: `FKIND_BOOL` and `FKIND_UNKNOWN` never
consume a lookahead; a typed flag registered via `flag_spec_register()` consumes one
if it has no inline value (`ERR_MISSING_VALUE` if none remains); a typed
flag registered via **`register_sep()`** (`libpdx-argv.ENH-010`) never
consumes a lookahead at all — only an inline `=`/`:` value satisfies it,
and no inline value is `ERR_MISSING_VALUE` regardless of what follows in
argv (`StdVocab` uses this for `--color`/`--no-cap`, whose I3 spellings
never had a lookahead form). The well-known `--pdx-schema` sets
`ParsedArgs::emit_schema`.

### typed.pdx — `Typed`

Value decoders for the string a typed flag captured. Each returns **ok in
`rax` (1/0), decoded value in `rdx`**; all are leaf functions. **All three
detect (rather than silently wrap on) a value that would exceed `u64::MAX`
and return `ok = 0` (`libpdx-argv.ENH-009`)** — a wrapped `--older-than`
or `--size` threshold is a correctness hazard this library no longer
produces.

| Function | Purpose |
| --- | --- |
| `parse_int_u64(str_ptr: u64) -> u64 !{mem} @{}` | `[0-9]+` terminated by NUL. At least one digit required; no sign, whitespace or suffix. |
| `parse_int_u64_ranged(str_ptr: u64, min: u64, max: u64) -> u64 !{mem} @{}` | **(`libpdx-argv.ENH-018`, Closes #28)** As `parse_int_u64`, plus a closed inclusive-unsigned `[min, max]` gate. Sentinel: `(min = 0, max = 0)` skips the gate entirely (behaves identically to `parse_int_u64`). On a range violation writes `ParsedArgs::error_code = ERR_INT_RANGE` (14) and returns `(0, 0)`; on a decode failure returns `(0, 0)` with `error_code` untouched. Uses unsigned compares end to end so the full u64 range works — `parse_int_u64_ranged("18446744073709551615", 1, 64)` is rejected here (upper cap) rather than by the decoder's overflow gate. |
| `parse_size(str_ptr: u64) -> u64 !{mem} @{}` | `[0-9]+` plus optional `k`/`K`, `m`/`M`, `g`/`G` → `<<10`, `<<20`, `<<30`. Result in bytes; binary units only. |
| `parse_timespan(str_ptr: u64) -> u64 !{mem} @{}` | `[0-9]+` plus optional `s`/`m`/`h`/`d` → ×1, ×60, ×3600, ×86400. Result in seconds; no suffix means seconds. |

### std_vocab.pdx — `StdVocab`

Ids `STD_ID_HELP` 1 … `STD_ID_NO_CAP` 9, with matching `STD_NAME_*`
NUL-terminated `.rodata` symbols. Tool-specific ids should start at 100.

| Function | Purpose |
| --- | --- |
| `register_all() -> () !{mem} @{}` | Register all nine I3 standard flags with `FlagSpec` — seven `FKIND_BOOL`, `color` as `FKIND_ENUM`, `no-cap` as `FKIND_STR`. Short aliases are deliberately *not* registered (they collide with per-tool vocabulary). |

### schema_invoke.pdx — `SchemaInvoke`

Wire constants: `SCHEMA_HEADER_SIZE` 32, `SCHEMA_FLAG_STRIDE` 16,
`SCHEMA_POS_STRIDE` 8, `SCHEMA_VERSION_V1` 1.

| Function | Purpose |
| --- | --- |
| `parse_from_schema_record(record_ptr: u64, record_len: u64) -> u64 !{mem} @{}` | The alternate invocation path: validate a v1 record, then fill the same `ParsedArgs` the argv path fills, consulting `FlagSpec::lookup` per flag. Returns `ERR_OK` or an `ERR_SCHEMA_*` / overflow code. |

Preconditions mirror `parse_argv`: `parsed_args_reset()` first, `FlagSpec`
already populated. Stored pointers are interior pointers into the caller's
record buffer and stay valid only while it is live.

**Offsets are validated (`libpdx-argv.ENH-001`).** Every `name_off` /
`value_off` (when nonzero) / `pos_off` must satisfy `off != 0 && off <
record_len` (unsigned) or the call fails with `ERR_SCHEMA_BAD_OFFSET`
(10); the resulting pointer is then scanned for a NUL byte before
`record_ptr + record_len`, or the call fails with
`ERR_SCHEMA_UNTERMINATED` (11). `error_arg_index` carries the failing
flag/positional loop index in both cases. `FlagSpec::lookup` is never
called on a pointer that failed either check — this is this library's
only untrusted-input surface (a peer process over a `KIND_IPC_ENDPOINT`)
and it is now bounds-checked end to end.

### help_backend.pdx — `HelpBackend`

`DOC_TOOL_NAME : [u8; 4] = "doc\0"` — the canonical `argv[0]` every
consumer's synthesized help invocation shares.

**(`libpdx-argv.ENH-014`, Closes #24.)** Library-owned `--help`
auto-table fallback. When `Parser::parse_argv` observes an argv
slot equal to `--help` (or a single-letter short flag whose id ==
`StdVocab::STD_ID_HELP`) AND the tool has opted into the fallback
via `HelpBackend::set_doc_unavailable(1)`, the parser calls
`HelpBackend::emit_from_argspec` and returns
`ParsedArgs::ERR_HELP_EMITTED` (15). The emitter walks the
`FlagSpec` table and writes one `--<name><TAB><help>\n` line to
fd 1 per registration whose `spec_help[i]` slot was populated via
`FlagSpec::register_with_help`; rows whose help slot is null are
silently suppressed. The gate is opt-IN — default preserves the
M3-002 dispatch where `--help` is stored as an ordinary flag for
the tool's own doc-forwarding code — so a tool that has `doc`
statically linked sees zero behavior change on `--help`.

| Function | Purpose |
| --- | --- |
| `fill_doc_argv(out_argv_slot_ptr: u64, tool_name_ptr: u64) -> () !{mem} @{}` | Write `(&DOC_TOOL_NAME, tool_name_ptr)` into a caller-owned `[u64; 2]`, so `--help` can hand `("doc", "<tool>")` to the `doc` renderer. Only the argv-fill primitive is exposed — a static dependency on `doc` would be circular. |
| `pdxargv_help_reset() -> () !{mem} @{}` | **(`libpdx-argv.ENH-014`)** Zero `doc_backend_unavailable` so the next parse defaults to the M3-002 dispatch. Called by `TestHarness::full_reset`. |
| `set_doc_unavailable(on: u64) -> () !{mem} @{}` | **(`libpdx-argv.ENH-014`)** `on != 0` opts the tool INTO the auto-table fallback; parse_argv then calls `emit_from_argspec` and returns `ERR_HELP_EMITTED` on every `--help` observation. |
| `emit_from_argspec() -> () !{mem} @{}` | **(`libpdx-argv.ENH-014`)** Writes `--<name><TAB><help>\n` to fd 1 for every registration whose `spec_help[i]` is non-null. Non-leaf (calls `help_strlen` twice per row). The parser calls this on the auto-emit path; consumers typically do not call it directly. |
| `help_strlen(s: u64) -> u64 !{mem} @{}` | **(`libpdx-argv.ENH-014`)** Byte-loop strlen over a NUL-terminated string. Leaf. Duplicated across `HelpBackend` and `VersionBackend` so each module's object has no cross-module link dependency. |

### version_backend.pdx — `VersionBackend`

**(`libpdx-argv.ENH-032`, Closes #25.)** Library-owned `--version`
auto-emitter. When `Parser::parse_argv` observes an argv slot equal to
`--version` (dispatched by id `== StdVocab::STD_ID_VERSION`, not by
name compare) AND the tool has not opted out via
`VersionBackend::set_override(1)`, the parser calls
`VersionBackend::emit_default` and returns
`ParsedArgs::ERR_VERSION_EMITTED` (13). The emitter writes
`<tool> <ver>\n<TOOL> VERSION OK\n` to fd 1 via seven raw sys_writes.
The `[legacy: <TOOL> VERSION OK]` line preserves the fingerprint the
paideia-os smoke drivers already grep for.

Two symbols are inputs to `emit_default`:

- **`HelpBackend::DOC_TOOL_NAME`** — the lowercase tool-name string
  (currently the fixed literal `"doc\0"`; see the `VersionBackend`
  module preamble for the coupling with `DOC_TOOL_NAME_UPPER`).
- **`PDX_TOOL_VERSION`** — an **extern** NUL-terminated ASCII string
  defined per-tool at build time in a per-repo constants module
  (e.g. `mkfs.pdxfs/src/version_constants.pdx`). The reference in
  `version_backend.o` is an UND relocation; a consumer that forgets
  to define it fails at ld with an undefined-symbol error naming
  `PDX_TOOL_VERSION` — a build-time catch, not a run-time surprise.
  No weak default is provided (paideia-as 0.36 does not currently
  expose STB_WEAK; a wrong-default fallback would silently pass
  `--version`).

| Function | Purpose |
| --- | --- |
| `pdxargv_version_reset() -> () !{mem} @{}` | Zero `override_enabled` so the next parse defaults to the auto-emit. Called by `TestHarness::full_reset`. |
| `set_override(on: u64) -> () !{mem} @{}` | `on != 0` opts the tool out of the auto-emit; parse_argv then stores `--version` as an ordinary flag and returns `ERR_OK`. |
| `emit_default() -> () !{mem} @{}` | Writes the frozen fingerprint to fd 1 via seven raw sys_writes. Non-leaf (calls `version_strlen`). The parser calls this on the auto-emit path; consumers typically do not call it directly. |
| `version_strlen(s: u64) -> u64 !{mem} @{}` | Byte-loop strlen over a NUL-terminated string. Leaf. |

Cap posture: `emit_default` issues sys_writes on fd 1. See
[`caps.decl`](caps.decl) for the narrowed language (pre-1.2 said
"performs NO syscalls of its own" — the version emitter is the
deliberate, single-purpose exception).

### schema_emit.pdx — `SchemaEmit`

Registry of the tool's declared output schema names, capacity
`SCHEMA_MAX = 8`. The library holds only the *table*; it cannot write to
stdout (no caps), so the actual printing is the consumer's job.

| Function | Purpose |
| --- | --- |
| `schema_emit_reset() -> () !{mem} @{}` | Clear the schema-name table. **(Renamed from `reset` in `libpdx-argv.ENH-030`, v1.1.0.)** |
| `schema_emit_register(schema_name_ptr: u64) -> () !{mem} @{}` | Append one NUL-terminated schema-name pointer; silently drops past `SCHEMA_MAX`. **(Renamed from `register` in `libpdx-argv.ENH-030`, v1.1.0.)** |
| `get_count() -> u64 !{mem} @{}` | Number of registered names. |
| `get_name(idx: u64) -> u64 !{mem} @{}` | Pointer to `schema_names[idx]`, or `0` if out of range. |
| `emit_parse_error(buf: u64, buflen: u64, argv_ptr: u64) -> u64 !{mem} @{}` | **(`libpdx-argv.ENH-016`, Closes #26)** Serialise one `PdxArgvParseErrorRecord@0.1` into a caller-supplied byte buffer on any parse failure. Reads `error_code` + `error_arg_index` from `ParsedArgs` and (given nonzero `argv_ptr`) `argv[error_arg_index]` as the offending token. Returns bytes written (the padded record size = `((32 + token_len + 7) / 8) * 8`), or `0` on `error_code == 0`, `buf == 0`, or `buflen < padded` (no partial writes — the record is atomic per invocation). |

### parse_error_record.pdx — `ParseErrorRecord`

Wire-form constants for the `PdxArgvParseErrorRecord@0.1` output
schema (see [Wire schema](#wire-schema-input-only-plus-one-output-record)
below for the on-wire layout). Pure `.rodata` — no functions, no
state.

| Symbol | Type | Meaning |
| --- | --- | --- |
| `PERR_HEADER_SIZE` | `u64 = 32` | Fixed header size; every conformant reader may assume `token_off >= 32`. |
| `PERR_VERSION_V1` | `u64 = 1` | Version qword the header carries at offset 8. |
| `PERR_TOKEN_OFFSET` | `u64 = 32` | Token region offset within the record; also emitted verbatim into the `token_off` header slot. |
| `PERR_MAGIC_BYTES` | `[u8; 8] = "PDXAPERR"` | 8 ASCII bytes, no NUL. Copied into the record with one qword move. |
| `PERR_SCHEMA_NAME_V01` | `[u8; 28] = "PdxArgvParseErrorRecord@0.1\0"` | Schema name a consumer publishes via `SchemaEmit::schema_emit_register` at bootstrap. |

## Wire schema (input only, plus one output record)

`caps.decl` declares one output schema (`declares_output_schemas:
- PdxArgvParseErrorRecord@0.1`, `libpdx-argv.ENH-016`, Closes #26).
`SchemaEmit::emit_parse_error` writes one record into a caller-supplied
buffer whenever `ParsedArgs::error_code` is nonzero. The record is
best-effort: it does not spawn a syscall, does not acquire any
capability, and produces zero bytes rather than a partial record on a
too-small buffer.

- **`PdxArgvParseErrorRecord@0.1`** — the ENH-016 output wire form
  written by `SchemaEmit::emit_parse_error`. v1 layout:

  | Offset | Size | Field |
  | --- | --- | --- |
  |  0 | 8 | magic `"PDXAPERR"` (no NUL) |
  |  8 | 8 | version (u64 LE; must be 1) |
  | 16 | 4 | `err_code`   (u32 LE; `ParsedArgs::ERR_*` code) |
  | 20 | 4 | `argv_index` (u32 LE; `ParsedArgs::error_arg_index`) |
  | 24 | 4 | `token_len`  (u32 LE; token bytes to follow, excluding NUL) |
  | 28 | 4 | `token_off`  (u32 LE; always 32 in v1) |
  | 32 | `token_len` | token bytes (verbatim argv-slot text, no NUL) |
  | next | 0..7 | zero padding to the next 8-byte boundary |

  Total = `((32 + token_len + 7) / 8) * 8` bytes.

**`libpdx-argv.ENH-003` (2026-08-25):** the 1.0 release declared a
second schema, `PdxArgvParsed@0.1` (a structured mirror of `ParsedArgs`,
supposedly emitted when a consumer opts into `--pdx-schema`), that never
had a producer anywhere in `src/` — `--pdx-schema` only ever set the
`emit_schema` bit. Withdrawn rather than implemented; no known consumer
depended on it. See `CHANGELOG.md`'s dated correction on the 1.0 entry.

The one wire schema this library actually READS is an **input**, not
an output — read by `SchemaInvoke::parse_from_schema_record`, never
produced by anything here:

- **`PdxArgvRecord@0.1`** — the alternate-invocation wire form read by
  `SchemaInvoke::parse_from_schema_record`. v1 layout:

  | Offset | Size | Field |
  | --- | --- | --- |
  | 0 | 8 | magic `"PDXARGV\0"` |
  | 8 | 8 | version (must be 1) |
  | 16 | 8 | `flag_count` (≤ 32) |
  | 24 | 8 | `pos_count` (≤ 32) |
  | 32 | 16 × `flag_count` | `{ u64 name_off, u64 value_off }` (`value_off == 0` → boolean) |
  | … | 8 × `pos_count` | `u64 pos_off` |
  | … | rest | NUL-terminated string table |

Envelope framing binds at `libpdx-semantic-pipe` M2/M3-001 — see that
repo for pipe schema definitions. The decoder here is self-contained:
`deps.list` records **no library dependencies**, and the wire shape is
*coordinated with* rather than linked against `libpdx-semantic-pipe`.

## Callers

Authoritative machine-readable list: [`pkgs/consumers.list`](pkgs/consumers.list)
(scaffolded by `libpdx-argv.ENH-029`, 2026-09-02). This section mirrors
that list in prose; keep the two in sync in every commit that adds or
removes a consumer.

Verified (`libpdx-argv.ENH-011`, 2026-08-25) by grepping each tool's own
`src/` for a call into this library's symbols (`parse_argv`,
`parsed_args_reset`, `register_all`, `parse_from_schema_record`,
`fill_doc_argv`) — 6 of the 9 R49+R50 P0 tools genuinely link and call
this library:

- [pkg](https://github.com/paideia-os/pkg) — `src/main.pdx:103`
  `call parse_argv`, dispatches on `ParsedArgs::pos_ptrs[0]`.
- [ls](https://github.com/paideia-os/ls) — `src/argv_surface.pdx:223,228`,
  an explicit "argv-facing wrapper around libpdx-argv::Parser", calling
  `parsed_args_reset` and `parse_argv` and branching on
  `ParsedArgs::emit_schema`.
- [cp](https://github.com/paideia-os/cp) — `src/main.pdx:125`
  `call register_all`, `:141` `call parse_argv`.
- [mkdir](https://github.com/paideia-os/mkdir) — `src/mkdir.pdx:1210`
  `call parse_argv`.
- [mv](https://github.com/paideia-os/mv) — `src/argv.pdx:194`
  `call parse_argv`.
- [rm](https://github.com/paideia-os/rm) — `src/main.pdx:130`
  `call parse_argv`.
- [mkfs.pdxfs](https://github.com/paideia-satellites/mkfs.pdxfs) —
  `src/argv.pdx` R90-XREPO ENH-030 shim: `flag_spec_reset` +
  `flag_spec_register` x11 + `parsed_args_reset` + `parse_argv` +
  `parse_int_u64` x2, walks `flag_ids[]`/`flag_values[]`/`pos_ptrs[]`
  to populate the tool's own fixed-offset ParsedArgv struct (11 flags:
  --force / --dry-run / --verbose / --upgrade / --help / --encrypt /
  --label / --journal-size / --sig-key / --passphrase-fd / --quota).
- [mount.pdxfs](https://github.com/paideia-satellites/mount.pdxfs) —
  `src/argv.pdx` R90-XREPO ENH-030 shim: `flag_spec_reset` +
  `flag_spec_register` x8 + `parsed_args_reset` + `parse_argv` +
  `parse_int_u64` x2, walks the same singletons (8 flags: --ro /
  --noexec / --verbose / --dry-run / --all / --snapshot-list /
  --snapshot / --passphrase-fd; --snapshot=<slot> ORs PA_FLAG_RO
  alongside its own presence bit).
- [umount.pdxfs](https://github.com/paideia-satellites/umount.pdxfs) —
  `src/argv.pdx` R90-XREPO ENH-030 shim: `flag_spec_reset` +
  `flag_spec_register` x4 + `parsed_args_reset` + `parse_argv`
  (4 boolean flags: --lazy / --force / --verbose / --dry-run;
  no `parse_int_u64` needed, no value-carrying flags).

Checked and **not** a caller, with the real reason each isn't:

- [cat](https://github.com/paideia-os/cat) — carries its own
  `ArgvDispatch::cat_parse_argv`; its source notes that migrating cat's argv
  surface to libpdx-argv is scheduled at cat.M3, kept off M2 to preserve
  byte-compat with the M1 golden fixtures. Tool-side, by plan.
- [doc](https://github.com/paideia-os/doc) — its own
  `src/argv_dispatch.pdx:206` inline positional scan carries the comment
  "M1: inline positional; M2: libpdx-argv" — migration is scheduled, not
  blocked. Tool-side, by plan.
- [shell](https://github.com/paideia-os/shell) — reimplements the parse
  discipline as its own `Pds` ("mirrors its `ParsedArgs` singleton
  discipline", per shell's README) rather than linking this library.
  This is the one library-side cause: `ParsedArgs`/`FlagSpec`/`SchemaEmit`
  are `.bss` singletons with one live parse context per process
  (`design/architecture.md` §3), which a multi-command-line shell can't
  adopt as shipped. See `libpdx-argv.ENH-006` (#17) for the caller-owned
  context that would unblock it.

Four P0 tools that link this library (`cp`, `ls`, `pkg`, `rm`) currently
ship an empty `deps.list`, so `pkg install --strict` would verify them
against a manifest that omits a library they actually link — a defect in
those four tool repos (and possibly a `deps.list`-lint gap in `pkg`), not
tracked in this repo.

## Version

**v1.1.0** — post-1.0 enhancement tranche (2026-09-02); folds Wave 1
(`libpdx-argv.ENH-022` / `ENH-023` / `ENH-029` — test-module rename,
smoke-driver qualification, `pkgs/consumers.list` scaffold) and Wave 2
(`libpdx-argv.ENH-030` — cross-module symbol rename to end the
`multiple definition of 'reset'` / `... 'register'` link error every
downstream P0 tool hit). See [`CHANGELOG.md`](CHANGELOG.md) for the 1.1
entry and the full post-1.0 tranche it groups; `VERSION` carries
`1.1.0`; `manifest.pdxsig` version-bumps in the same commit;
`STATUS.md` and `design/tooling/r49-r50-plan.md` §5.12 in
[paideia-os](https://github.com/paideia-os/paideia-os) carry the wave
rubric context. The v1.0.0 entry (first signed release, 2026-08-22,
milestones M1–M5 all closed) is left in place per this repo's policy
of not rewriting a signed release's history silently.

## Examples

**Bootstrap and parse.** Registration must precede the parse — the parser
consults `FlagSpec` to decide flag arity. Consumers invoked from `_start`
should call `parse_argv_skipping_zero` so `argv[0]` (the program name)
does not land in `pos_ptrs[0]`.

```pdx
flag_spec_reset()
register_all()                                        // the 9 I3 flags, ids 1..9
flag_spec_register(&MY_NAME_OUT, FlagSpec::FKIND_STR,  100)
flag_spec_register(&MY_NAME_MAX, FlagSpec::FKIND_SIZE, 101)
parsed_args_reset()
let rc = parse_argv_skipping_zero(argv, argc)         // 0 = ERR_OK
// (or: parse_argv(argv+8, argc-1) — same effect, hand-computed offset)
```

**Dispatch by id, then decode the value.** `find_flag_by_id` returns `32`
when the flag was absent; `Typed::*` return `(ok, value)` in `rax:rdx`.

```pdx
let k = ParsedArgs::find_flag_by_id(StdVocab::STD_ID_HELP)
if k != 32 {
  let mut argv_slots : [u64; 2] = uninit @align(8)
  HelpBackend::fill_doc_argv(&argv_slots[0], MY_TOOL_NAME)
  exit(DocDispatch::doc_dispatch(&argv_slots[0], 2))
}

let m = ParsedArgs::find_flag_by_id(101)              // --max=<size>
if m != 32 {
  let (ok, bytes) = Typed::parse_size(ParsedArgs::flag_values[m])
  // "4k" -> 4096, "2M" -> 2097152; ok == 0 on malformed input
}
```

**Invocation through a semantic pipe.** Same setup, different entry point;
everything downstream reads `ParsedArgs` unchanged.

```pdx
flag_spec_reset()
register_all()
parsed_args_reset()
let rc = parse_from_schema_record(rec_ptr, rec_len)
// rc == 7/8/9 -> bad magic / unsupported version / bad layout
```

## License

MIT — see [LICENSE](LICENSE).
