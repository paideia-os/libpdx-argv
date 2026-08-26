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
(reserved), `ERR_CLUSTERED_SHORT` 4, `ERR_LONG_MISSING_NAME` 5,
`ERR_MISSING_VALUE` 6, `ERR_SCHEMA_BAD_MAGIC` 7,
`ERR_SCHEMA_UNSUPPORTED_VERSION` 8, `ERR_SCHEMA_BAD_LAYOUT` 9,
`ERR_SCHEMA_BAD_OFFSET` 10, `ERR_SCHEMA_UNTERMINATED` 11,
`ERR_UNKNOWN_FLAG` 12 (opt-in strict mode only — see `FlagSpec::set_strict`).

| Function | Purpose |
| --- | --- |
| `reset() -> () !{mem} @{}` | Zero the bookkeeping slots so the next parse starts clean. Arrays are consumed by index, so only counters are cleared. |
| `find_flag_by_id(id: u64) -> u64 !{mem} @{}` | Linear scan of `flag_ids`; returns the storage index `k`, or `32` (`MAX_FLAGS`) if that id was never seen. **First-wins** on a repeated flag (`libpdx-argv.ENH-008`). |
| `find_last_flag_by_id(id: u64) -> u64 !{mem} @{}` | **(ENH-008)** Same as above but **last-wins** — scans downward, so a later occurrence of a repeated flag shadows an earlier one (e.g. `--color=auto --color=never` → `never`). |
| `count_flag_by_id(id: u64) -> u64 !{mem} @{}` | **(ENH-008)** Number of stored flags with the given id (0 if never seen) — for the repeat-count idiom (`-v -v -v`). |

### flag_spec.pdx — `FlagSpec`

Declarative flag table, capacity `SPEC_MAX = 32`. Value kinds:
`FKIND_BOOL` 0, `FKIND_STR` 1, `FKIND_INT` 2, `FKIND_TIMESPAN` 3,
`FKIND_SIZE` 4, `FKIND_ENUM` 5, and the miss sentinel `FKIND_UNKNOWN` `0xFF`.

| Function | Purpose |
| --- | --- |
| `reset() -> () !{mem} @{}` | Clear the registration table (zeroes `spec_count`). |
| `register(name_ptr: u64, kind: u64, id: u64) -> () !{mem} @{}` | Append one `(name, kind, id)` triple. Silently no-ops past `SPEC_MAX`. |
| `lookup(name_ptr: u64) -> u64 !{mem} @{}` | Inline-strcmp scan; returns **kind in `rax`, id in `rdx`**. Miss yields `FKIND_UNKNOWN` / id 0 — unregistered flags are treated as boolean. |
| `set_strict(on: u64) -> () !{mem} @{}` | **(`libpdx-argv.ENH-004`)** Opt into strict mode: `on != 0` makes both `Parser::parse_argv` and `SchemaInvoke::parse_from_schema_record` fail with `ERR_UNKNOWN_FLAG` (12) on any `lookup` miss instead of storing the flag as boolean. Defaults to 0 (permissive); `reset()` restores 0. |

### parser.pdx — `Parser`

| Function | Purpose |
| --- | --- |
| `parse_argv(argv: u64, argc: u64) -> u64 !{mem} @{}` | The text-CLI entry point. Walks `argv`, classifies each slot, fills `ParsedArgs`, returns `ERR_OK` or an `ERR_*` code (also recorded with the offending index in `error_arg_index`). |

Grammar: long flags `--foo`, `--foo=bar`, `--foo:bar`, `--foo bar`; short
flags one letter per hyphen (`-f`; clustered `-la` is rejected with
`ERR_CLUSTERED_SHORT`); a bare `-` is positional; `--` is a sentinel after
which every remaining argument is positional regardless of leading byte.
Arity comes from `FlagSpec::lookup`: `FKIND_BOOL` and `FKIND_UNKNOWN` never
consume a lookahead, every other kind always does (`ERR_MISSING_VALUE` if
none remains). The well-known `--pdx-schema` sets `ParsedArgs::emit_schema`.

### typed.pdx — `Typed`

Value decoders for the string a typed flag captured. Each returns **ok in
`rax` (1/0), decoded value in `rdx`**; all are leaf functions.

| Function | Purpose |
| --- | --- |
| `parse_int_u64(str_ptr: u64) -> u64 !{mem} @{}` | `[0-9]+` terminated by NUL. At least one digit required; no sign, whitespace or suffix. |
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

Preconditions mirror `parse_argv`: `ParsedArgs::reset()` first, `FlagSpec`
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

| Function | Purpose |
| --- | --- |
| `fill_doc_argv(out_argv_slot_ptr: u64, tool_name_ptr: u64) -> () !{mem} @{}` | Write `(&DOC_TOOL_NAME, tool_name_ptr)` into a caller-owned `[u64; 2]`, so `--help` can hand `("doc", "<tool>")` to the `doc` renderer. Only the argv-fill primitive is exposed — a static dependency on `doc` would be circular. |

### schema_emit.pdx — `SchemaEmit`

Registry of the tool's declared output schema names, capacity
`SCHEMA_MAX = 8`. The library holds only the *table*; it cannot write to
stdout (no caps), so the actual printing is the consumer's job.

| Function | Purpose |
| --- | --- |
| `reset() -> () !{mem} @{}` | Clear the schema-name table. |
| `register(schema_name_ptr: u64) -> () !{mem} @{}` | Append one NUL-terminated schema-name pointer; silently drops past `SCHEMA_MAX`. |
| `get_count() -> u64 !{mem} @{}` | Number of registered names. |
| `get_name(idx: u64) -> u64 !{mem} @{}` | Pointer to `schema_names[idx]`, or `0` if out of range. |

## Schemas exposed

Two, both declared in `caps.decl` under `declares_output_schemas:` and
sharing the `libpdx-semantic-pipe` fingerprint namespace:

- **`PdxArgvParsed@0.1`** — structured mirror of `ParsedArgs`, emitted when
  the consumer opts into `--pdx-schema`. Lets a downstream tool introspect a
  peer's parsed invocation without re-running the parser.
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

Envelope framing for both binds at `libpdx-semantic-pipe` M2/M3-001 — see
that repo for pipe schema definitions. The decoder here is self-contained:
`deps.list` records **no library dependencies**, and the wire shape is
*coordinated with* rather than linked against `libpdx-semantic-pipe`.

## Callers

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

**v1.0.0** — first signed release (2026-08-22); milestones M1–M5 all closed.
`VERSION` carries `1.0.0`; `manifest.pdxsig` is the dual-signed release
manifest; `doc/libpdx-argv.pdxdoc` is the `doc libpdx-argv` page per I7; and
`pkgs/mirror.entry` is the admission entry for the `pkgs.paideia-os` mirror.
See [`CHANGELOG.md`](CHANGELOG.md) for the 1.0 entry, `STATUS.md` for the
per-milestone rollup, and `design/tooling/r49-r50-plan.md` §5.12 in
[paideia-os](https://github.com/paideia-os/paideia-os) for the wave rubric.

## Examples

**Bootstrap and parse.** Registration must precede the parse — the parser
consults `FlagSpec` to decide flag arity.

```pdx
FlagSpec::reset()
StdVocab::register_all()                              // the 9 I3 flags, ids 1..9
FlagSpec::register(&MY_NAME_OUT, FlagSpec::FKIND_STR,  100)
FlagSpec::register(&MY_NAME_MAX, FlagSpec::FKIND_SIZE, 101)
ParsedArgs::reset()
let rc = Parser::parse_argv(argv, argc)               // 0 = ERR_OK
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
FlagSpec::reset()
StdVocab::register_all()
ParsedArgs::reset()
let rc = SchemaInvoke::parse_from_schema_record(rec_ptr, rec_len)
// rc == 7/8/9 -> bad magic / unsupported version / bad layout
```

## License

MIT — see [LICENSE](LICENSE).
