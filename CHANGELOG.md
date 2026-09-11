# libpdx-argv — CHANGELOG

All notable changes to `libpdx-argv` are recorded here. The format is
loosely modelled on Keep-a-Changelog, adapted to the PaideiaOS milestone
rubric in `design/tooling/r49-r50-plan.md` §5.

## Unreleased

### ENH-016 — `PdxArgvParseErrorRecord@0.1` structured error emission (Closes #26)

First OUTPUT wire schema this library declares. `SchemaEmit` gains
one new entry point, `emit_parse_error(buf, buflen, argv_ptr)`,
that serialises a single 32-byte-header record (plus verbatim
token bytes, padded to 8) into a caller-supplied buffer whenever
`ParsedArgs::error_code` is nonzero. New `.rodata`-only module
`ParseErrorRecord` (`src/parse_error_record.pdx`) owns the wire
constants: magic `"PDXAPERR"` (8 ASCII bytes, no NUL), version
qword `1`, fixed header size `32`, token offset `32`, and the
28-byte schema-name string `"PdxArgvParseErrorRecord@0.1\0"` a
consumer publishes via `SchemaEmit::schema_emit_register` at
bootstrap. `caps.decl` flips `declares_output_schemas:` from
`(none)` to a one-line block naming the record.

Wire layout (v1). All fields little-endian; header exact 32
bytes; tail zero-padded to 8-byte alignment so a consumer
streaming multiple records back-to-back never re-aligns.

  | Offset | Size | Field       |
  | --- | --- | --- |
  |  0 | 8 | magic `"PDXAPERR"` |
  |  8 | 8 | version = 1        |
  | 16 | 4 | err_code (u32; `ParsedArgs::ERR_*` code) |
  | 20 | 4 | argv_index (u32; `ParsedArgs::error_arg_index`) |
  | 24 | 4 | token_len (u32) |
  | 28 | 4 | token_off (u32; always 32 in v1) |
  | 32 | token_len | token bytes (no NUL) |
  | next | 0..7 | zero padding |

Total = `((32 + token_len + 7)/8)*8` bytes.

API decisions:

  - **Three arguments, not two.** The naïve `(buf, buflen)`
    shape would require a new `ParsedArgs::error_token_ptr` slot
    with a stash pass inside `parse_argv_fail`. Passing
    `argv_ptr` as the third argument lets `emit_parse_error`
    derive the token via `argv[error_arg_index]` at emit time
    with zero parser change, and lets a SchemaInvoke-path caller
    (which has no argv) pass `argv_ptr = 0` to get a header-only
    record with `token_len = 0`.
  - **Atomic per invocation.** `buflen < padded` returns `0`
    without writing any bytes. No partial writes; the caller
    reserves a scratch buffer sized for its longest plausible
    argv slot (128 bytes covers every I3 flag spelling with room
    to grow — the longest today is `--no-cap:KIND_IPC_ENDPOINT`
    at 25 bytes).
  - **`token_off` is an explicit field, not an implicit constant.**
    Always 32 in v1; emitted so a v2 header extension can grow
    past 32 bytes without a wire re-cut. A v1 reader that finds
    `token_off != 32` refuses the record.
  - **No `flag_id` or `reserved` slots.** The issue draft
    included both; both dropped. `flag_id` would be 0 in the
    only ERR_* that would carry a meaningful one today
    (`ERR_UNKNOWN_FLAG`, whose FKIND_UNKNOWN sentinel id IS 0);
    consumers wanting it look it up themselves via
    `FlagSpec::lookup(argv[error_arg_index])`. `reserved` is
    what `token_off` guards against — a v2 with real content
    for those bytes fits a purpose-built field better than
    preallocated space.

Fingerprint (issue #26, verified by `tests/schema_emit.pdx`
run_case6): after
`FlagSpec::set_strict(1); parse_argv(["tool","--zog"], 2)` sets
`error_code = 12` (`ERR_UNKNOWN_FLAG` per parsed_args.pdx),
`emit_parse_error(&buf, 128, &argv)` returns `40` and writes a
record whose header carries magic `"PDXAPERR"` (bytes 0x50 0x44
0x58 0x41 0x50 0x45 0x52 0x52 at buf[0..8]), version `1`,
`err_code = 12`, `argv_index = 1`, `token_len = 5`,
`token_off = 32`, and the five bytes of `"--zog"` at
buf[32..37], with three zero-pad bytes at buf[37..40].

Files touched:

  - `src/parse_error_record.pdx` — NEW; `.rodata`-only module with
     `PERR_MAGIC_BYTES` / `PERR_VERSION_V1` / `PERR_HEADER_SIZE` /
     `PERR_TOKEN_OFFSET` / `PERR_SCHEMA_NAME_V01`.
  - `src/schema_emit.pdx` — adds `emit_parse_error` (leaf; no
     push/pop, no callee-save touched, inline strlen for the
     token length). Module preamble extended with the ENH-016
     compliance notes (mov_d for u32 stores, mov_b for the token
     copy loop, `add 7; shr 3; shl 3` for align-up rather than
     `and reg,imm64`).
  - `tests/schema_emit_tests.pdx` — new `run_case6` verifying the
     fingerprint byte-by-byte (magic, version qword, four u32
     fields via mov_d, five token bytes, three pad bytes).
  - `tests/smoke_driver.pdx` — dispatches `SchemaEmitTests::run_case6`
     after case5.
  - `doc/libpdx-argv.pdxdoc` — new `.section OUTPUT SCHEMAS`
     ahead of `CROSS-REFERENCES` documenting the wire form,
     semantics, bounds discipline, and consumer wiring.
  - `caps.decl` — `declares_output_schemas:` flipped from
     `(none)` to a one-line block naming
     `PdxArgvParseErrorRecord@0.1`; preamble notes the same-
     silent-write-policy carve-out that ENH-014/ENH-032 use.
  - `design/architecture.md` — new §15 covering wire form,
     module surface delta, the three-argument rationale,
     `token_off` as an explicit field, and the "explicitly does
     not do" list.
  - `README.md` — SchemaEmit table gains the `emit_parse_error`
     row; a new `parse_error_record.pdx` subsection documents
     the constants; the "Wire schema" section is renamed to
     "Wire schema (input only, plus one output record)" and
     the output layout is spelled out.

Klog tag: `pdxargv.err-emit`.

### ENH-014 — Auto `--help` table generated lazily from ArgSpec (Closes #24)

`FlagSpec` gains a new per-slot array `spec_help : [u64; 32]` — a
NUL-terminated help-text pointer, or `0` for "no help text on this
row". A new registration variant
`register_with_help(name_ptr, kind, id, help_ptr)` populates this
slot; the existing 3-arg `flag_spec_register` becomes a thin wrapper
that calls `register_with_help` with `help_ptr = 0` (behaviour
preserved for every existing consumer). `register_sep` and
`register_int` gain a defensive `spec_help[slot] = 0` store in the
same shape they already zero `spec_sep_required` / `spec_min` /
`spec_max`, so a slot recycled across a `register_with_help() →
register_sep()` (or `→ register_int()`) sequence never inherits a
stale help pointer.

`HelpBackend` gains:

  - `LIT_DDASH` / `LIT_TAB` / `LIT_LF` — the three `.rodata`
     literals `emit_from_argspec` writes verbatim per row
     (`--`, tab 0x09, and LF 0x0A). The tab is written as `"\t\0"`
     the same way `VersionBackend::LIT_NEWLINE` writes `"\n\0"`.
  - `doc_backend_unavailable : u64` (.bss) — 0 (default; restored
     by `pdxargv_help_reset`) means the `doc` back-end IS available
     in the tool's address space (the M3-002 dispatch: `--help` is
     stored as an ordinary flag for the tool's own doc-forwarding
     code); nonzero means the tool has explicitly signalled
     unavailability and wants the in-process fallback.
  - `pdxargv_help_reset() -> ()` — leaf; zeros
     `doc_backend_unavailable`. Wired into
     `TestHarness::full_reset` so a case that opts in never leaks
     the opt-in into the case after.
  - `set_doc_unavailable(on: u64) -> ()` — leaf; stores `rdi` into
     `doc_backend_unavailable`. Any nonzero value trips the auto-
     emit gate (`cmp doc_backend_unavailable, 0; je skip`); the `1`
     convention is documented in the module preamble.
  - `help_strlen(s: u64) -> u64` — leaf; byte-loop strlen, same
     shape as `VersionBackend::version_strlen`. Duplicated across
     the two modules so `help_backend.o` has no link dependency on
     `version_backend.o`.
  - `emit_from_argspec() -> ()` — non-leaf; 3-push prologue
     (rbx / r12 / r13). Walks `spec_names` / `spec_help` /
     `spec_count`, writing `--<name><TAB><help>\n` to fd 1 per
     registration whose `spec_help[i]` slot is non-null. Five
     `sys_write` calls per non-null row (literal `--` + name +
     TAB + help + LF); rows whose help slot is 0 are silently
     suppressed. Called by `Parser::parse_argv` immediately after
     it stores a `--help` observation whose id equals
     `StdVocab::STD_ID_HELP` (1) AND `doc_backend_unavailable != 0`.

`Parser::parse_argv` dispatches on both the long-flag store path
and the single-letter short-flag store path (StdVocab does not
register a `-h` alias — a `-h` would collide with `head` / `hexdump`
conventions — so the short path only fires for a tool that
explicitly registered a single-letter short flag with id ==
STD_ID_HELP). The gate is opt-IN: default
`doc_backend_unavailable == 0` preserves M3-002 semantics, so a
tool that has `doc` statically linked sees zero behavior change
on `--help`. On the auto-emit path the parser returns
`ParsedArgs::ERR_HELP_EMITTED` (15) via the shared
`parse_argv_fail` epilogue every other `ERR_*` code takes — a
consumer's existing `if err != ERR_OK { … }` branch fires
uniformly; the tool exits 0 in response.

Fingerprint (issue #24): with `StdVocab::register_all` and three
tool-specific flags registered via `register_with_help` (each with
help text set) AND `HelpBackend::set_doc_unavailable(1)` in effect,
`parse_argv(["--help"], 1)` returns `ERR_HELP_EMITTED = 15` in rax,
writes 15 into `ParsedArgs::error_code`, and issues exactly 3 ×
5 = 15 `sys_write`s to fd 1 realising three `--<name><TAB><help>\n`
lines. Rows whose help slot is null are suppressed — a tool that
populates only 2 of 10 slots emits exactly 2 rows. Without the
`set_doc_unavailable(1)` opt-in, `parse_argv(["--help"], 1)`
returns `ERR_OK` and stores `--help` as an ordinary flag exactly
as before.

Files touched:

  - src/parsed_args.pdx
      +`ERR_HELP_EMITTED = 15` constant, docstring naming the
       success-signal semantics (parity with `ERR_VERSION_EMITTED`).

  - src/flag_spec.pdx
      +`spec_help : [u64; 32]` .bss array, with the "0 → row
       suppressed" lazy-generation contract documented on the slot
       declaration.
      +`register_with_help(name_ptr, kind, id, help_ptr)` — the
       canonical full-shape registration path; leaf.
      *`flag_spec_register` is now a thin wrapper that xors rcx to 0
       and tail-calls `register_with_help` (1-push rbx for
       alignment). Preserves the M2 3-arg registration surface.
      *`register_sep` / `register_int` — defensive
       `spec_help[slot] = 0` store added alongside the existing
       `spec_sep_required` / `spec_min` / `spec_max` stores.

  - src/help_backend.pdx
      +`LIT_DDASH` (`"--\0"`), `LIT_TAB` (`"\t\0"`), `LIT_LF`
       (`"\n\0"`) .rodata literals.
      +`doc_backend_unavailable : u64` .bss slot (opt-in gate;
       default 0 = doc available; nonzero = doc unavailable, auto-
       emit fires).
      +`pdxargv_help_reset()` — leaf; zeros the gate slot.
      +`set_doc_unavailable(on)` — leaf; stores rdi.
      +`help_strlen(s) -> len` — leaf; byte-loop strlen mirroring
       `VersionBackend::version_strlen` in shape.
      +`emit_from_argspec()` — non-leaf; 3-push prologue; walks
       FlagSpec and writes one `--<name><TAB><help>\n` per non-null
       row via 5 sys_writes.

  - src/parser.pdx
      *`parse_argv` — after every long-flag OR single-letter short-
       flag store, checks `r15 == 1` (`STD_ID_HELP`) AND
       `doc_backend_unavailable != 0`. On both hits, calls
       `emit_from_argspec` and returns `ERR_HELP_EMITTED` via
       `parse_argv_fail`. The 6-push + `sub rsp,8` prologue that
       already aligned `rsp%16 = 0` for the nested `FlagSpec::lookup`
       and `VersionBackend::emit_default` calls covers the new
       `emit_from_argspec` call site without any bookkeeping change.

  - tests/harness.pdx
      *`TestHarness::full_reset` — fifth nested reset call:
       `pdxargv_help_reset` (symmetric with the ENH-032
       `pdxargv_version_reset` addition).

  - tests/help_backend_tests.pdx
      +`run_case4` — the lazy-emit fingerprint case; registers 3
       tool-specific flags with help set, opts into the fallback
       via `set_doc_unavailable(1)`, asserts
       `parse_argv(["--help"], 1)` returns
       `ERR_HELP_EMITTED = 15` and records 15 into
       `ParsedArgs::error_code`.

  - tests/smoke_driver.pdx
      *Registers `HelpBackendTests::run_case4` in the smoke run.

  - design/architecture.md, README.md, doc/libpdx-argv.pdxdoc
      *Documented the new registration path, the opt-in gate, the
       auto-emit fingerprint, and the interaction with M3-002's
       `fill_doc_argv` dispatch.

Caps.decl impact: `emit_from_argspec` issues `sys_write` on fd 1
(5 syscalls per non-null row). The `caps.decl` narrowed language
already carved out `VersionBackend::emit_default` as a deliberate
single-purpose exception to the library's "no syscalls of its own"
line; ENH-014 extends that carve-out to the second library-owned
emitter. Consumers holding a `KIND_TTY` / `KIND_IPC_ENDPOINT` cap
on fd 1 see the writes hit stdout; consumers that do not see the
syscalls fail with `-EBADF` and this function returns anyway —
same silent-write policy `emit_default` uses.

New klog tag: `pdxargv.help-auto` (identifier a klog subscriber
uses to correlate an auto-emit with the argv slot that triggered
it once the kernel-side klog substrate lands, R51+).

### ENH-018 — INT flag range validation (min/max on ArgSpec) (Closes #28)

`FlagSpec` gains two new per-slot arrays, `spec_min` and `spec_max`
(both `[u64; 32]`), and a new registration variant
`register_int(name_ptr, id, min, max)` that appends an INT-kinded flag
with the caller-chosen inclusive unsigned interval `[min, max]`
published into those slots. `Typed` gains a new decoder wrapper
`parse_int_u64_ranged(str_ptr, min, max)` that delegates decoding to
the unchanged `parse_int_u64` and then applies the range gate using
unsigned compares end to end (`jb` / `ja`). On a range violation the
wrapper writes the new `ParsedArgs::ERR_INT_RANGE` (= 14) into
`error_code` and returns `(ok = 0, val = 0)`; on a decode failure it
returns `(0, 0)` with `error_code` untouched (the pre-ENH-018 Typed
convention that a decode failure does not set an error_code is
preserved so a consumer that only inspects the `ok` return behaves
the same whether it called `parse_int_u64` or the ranged variant).

Sentinel semantics (the "no range check runs" half of the
fingerprint): a `(min = 0, max = 0)` pair is treated as "range OFF"
and skips the gate entirely — the ranged decoder then behaves
identically to `parse_int_u64`. `flag_spec_register` (the plain
registration path) and `register_sep` both write `(0, 0)` into the
new slots defensively, so every existing INT registration is
transparent to the gate and a slot recycled across registration
batches never inherits stale bounds.

A companion accessor `FlagSpec::get_range_by_id(id) -> (min in rax,
max in rdx)` provides a round-trip: consumers that stored a flag's
id (StdVocab or tool-specific) can recover the `(min, max)` pair
they originally registered without having to remember the bounds
locally, e.g. when the dispatch code that calls `parse_int_u64_ranged`
is physically separated from the registration bootstrap. It returns
`(0, 0)` both for an unregistered id AND for a flag registered
without a range — indistinguishable at this API, by design; callers
that need to tell them apart call `lookup()` first.

Fingerprint (issue #28): with `register_int("--jobs", ID_JOBS, 1,
64)`, `parse_int_u64_ranged("32", 1, 64)` returns `(1, 32)` with
`error_code = ERR_OK`; `"0"` returns `(0, 0)` with `error_code =
ERR_INT_RANGE`; `"65"` returns `(0, 0)` with `error_code =
ERR_INT_RANGE`; `"18446744073709551615"` (u64::MAX exactly, which
`parse_int_u64` accepts per ENH-009 case18) returns `(0, 0)` with
`error_code = ERR_INT_RANGE` — the upper-cap trip is against the
decoded value, not against a wrap. With the plain
`flag_spec_register("--jobs", FKIND_INT, ID_JOBS)`,
`parse_int_u64_ranged` called with `(min = 0, max = 0)` returns
`(1, 0)` for `"0"` — the sentinel bypass. New klog tag:
`pdxargv.int-range`.

Files touched:

  - src/parsed_args.pdx
      +`ERR_INT_RANGE = 14` constant, with the docstring naming the
       sentinel semantics and the unsigned-compare-end-to-end
       requirement.

  - src/flag_spec.pdx
      +`spec_min : [u64; 32]` / `spec_max : [u64; 32]` .bss arrays,
       with the "(0, 0) = range OFF" sentinel documented on the
       slot declarations.
      +`register_int(name_ptr, id, min, max)` — kind is fixed to
       `FKIND_INT` (2); publishes `(min, max)` into the new slots
       and zeroes `spec_sep_required[slot]` for parity with the
       plain registration's default arity.
      +`get_range_by_id(id) -> (min in rax, max in rdx)` — companion
       lookup helper for round-trip retrieval of the registered
       bounds.
      *`flag_spec_register` and `register_sep` updated to
       defensively zero `spec_min[slot]` / `spec_max[slot]` in
       addition to `spec_sep_required[slot]`, so a slot recycled
       across a `register_int()` → plain-register or → sep-register
       call never inherits stale bounds.

  - src/typed.pdx
      +`parse_int_u64_ranged(str_ptr, min, max) -> (ok, val)` —
       non-leaf wrapper around `parse_int_u64` with a 3-push
       prologue that aligns rsp%16 for the nested call and
       preserves `(min, max)` across it (rbp/r12) plus a `rbx` spill
       for `val`. Sentinel-first, then closed-interval gate; on
       range violation publishes `ERR_INT_RANGE` and returns
       `(0, 0)`.
      *Module compliance preamble carries a new "EXCEPTION" line
       naming `parse_int_u64_ranged` as the sole non-leaf in the
       module.

  - tests/parse_typed_values_tests.pdx
      +cases 25-29 (module id 2):
         25: `parse_int_u64_ranged("32", 1, 64)` → `(1, 32)`;
             `error_code` STILL 0 (contract: success does not touch
             it).
         26: `parse_int_u64_ranged("0", 1, 64)` → `(0, —)`;
             `error_code = 14`. Below-min branch (`jb`).
         27: `parse_int_u64_ranged("65", 1, 64)` → `(0, —)`;
             `error_code = 14`. Above-max branch (`ja`).
         28: `parse_int_u64_ranged("18446744073709551615", 1, 64)`
             → `(0, —)`; `error_code = 14`. Upper-cap-not-wrap
             witness: the decoded u64::MAX (case18 proves it
             decodes) is rejected by the range gate, not by
             overflow. Also proves the gate is unsigned end to
             end — a signed `jg` would erroneously ACCEPT this.
         29: `parse_int_u64_ranged("0", 0, 0)` → `(1, 0)`;
             `error_code` STILL 0. Sentinel witness: the plain
             `flag_spec_register` path writes `(0, 0)` into the
             new slots, so a consumer forwarding those bounds
             sees the gate bypass.
      +`f_int_32` / `f_int_65` fixtures; reuses existing
       `f_int_zero` and `f_int_u64_max` for the low-end and
       upper-cap-not-wrap cases so no per-case literal duplication.

  - tests/smoke_driver.pdx
      +five `call ParseTypedValuesTests::run_case25..29` entries
       under a comment naming ENH-018.

  - design/architecture.md
      +§13 "INT flag range validation (ENH-018, Closes #28)"
       documenting the new FlagSpec slots, the register_int
       signature and its (0, 0) sentinel, the parse_int_u64_ranged
       wrapper's error_code discipline, the unsigned-compare-end-
       to-end contract, and the two explicit non-goals (no
       register_int_sep variant yet; get_range_by_id does not
       distinguish "no range" from "unregistered").

  - README.md
      +`register_int` row in the flag_spec.pdx table.
      +`parse_int_u64_ranged` row in the typed.pdx table with an
       inline note on the sentinel.
      +`ERR_INT_RANGE` (14) in the error-code constants list
       naming ENH-018 / Closes #28.

  - doc/libpdx-argv.pdxdoc
      +`ERR_INT_RANGE` (14) entry in the DIAGNOSTICS section,
       naming ENH-018 / #28 and the pdxargv.int-range klog tag.
      +STANDARD FLAGS section preamble note that a tool-specific
       INT flag can be registered with an inclusive `[min, max]`
       via the new `register_int(name, id, min, max)` variant.

Downstream migration: no existing consumer breaks. `parse_int_u64`
is unchanged. `flag_spec_register` and `register_sep` grow two
defensive writes into the new slots; existing callers see no
behaviour change. A consumer that wants a bounded INT flag
switches its own call site from `flag_spec_register(name,
FKIND_INT, id)` to `register_int(name, id, min, max)` on the same
commit that bumps its libpdx-argv pin, and calls
`parse_int_u64_ranged` (with either its own remembered bounds or
`get_range_by_id`-recovered ones) in place of `parse_int_u64` at
the dispatch site.

### ENH-032 — Library-owned `--version` auto-emitter (Closes #25)

`StdVocab::register_all` reserves `--version` (id `STD_ID_VERSION` =
2) but the M2 shape left every consumer to re-implement the emit
path: build `<tool> <ver>\n<TOOL> VERSION OK\n` in tool-local
`.rodata`, sys_write it, exit 0 — 20-odd lines of near-identical
boilerplate duplicated across six P0 satellites (`mkfs.pdxfs`,
`mount.pdxfs`, `umount.pdxfs`, `libpdx-audit`, `libpdx-elevate`,
`shell`) and every satellite the next wave adds. ENH-032 lifts the
emit into a new library module `VersionBackend`
(`src/version_backend.pdx`); `Parser::parse_argv` dispatches to it
when the just-stored flag's id equals `STD_ID_VERSION` AND the tool
has not opted out via `VersionBackend::set_override(1)`.

Contract (frozen):

  Parser::parse_argv observes an argv slot == "--version"
    → VersionBackend::emit_default writes to fd 1, via seven
      sys_write syscalls, the byte sequence:
        <DOC_TOOL_NAME bytes>' '<PDX_TOOL_VERSION bytes>'\n'
        <DOC_TOOL_NAME_UPPER bytes>' VERSION OK\n'
    → ParsedArgs::error_code = ERR_VERSION_EMITTED (13)
    → parse_argv returns ERR_VERSION_EMITTED

Dispatch is by id, not by name compare — a tool that registers
`--version` with a non-2 id (say 100) keeps StdVocab's other 8 flags
but takes the emit path itself. The check runs in both the
long-flag and short-flag store paths for symmetry (StdVocab does
not register a short alias for `--version`, but a tool wanting a
`-V` alias for the library-owned auto-emit gets it by calling
`flag_spec_register(&NAME_V, FKIND_BOOL, 2)` after `register_all`).

Extern discipline: `PDX_TOOL_VERSION` is a per-tool
NUL-terminated ASCII string in `.rodata` defined by the consumer's
own constants module (e.g. `mkfs.pdxfs/src/version_constants.pdx`).
`version_backend.o` carries an UND relocation on the symbol; a
consumer that forgets to define it fails at ld with an
undefined-symbol error naming `PDX_TOOL_VERSION` — a build-time
catch, not a run-time surprise. No weak default is provided
(paideia-as 0.36 does not expose STB_WEAK, and a wrong-default
fallback would silently pass under `--version`).

`HelpBackend::DOC_TOOL_NAME` supplies the lowercase tool-name half
per the issue contract. That symbol is today the fixed literal
`"doc\0"` — every tool's auto-emit therefore says
`doc <ver>\nDOC VERSION OK\n`. Making it per-tool is a follow-on
ENH (promote DOC_TOOL_NAME / DOC_TOOL_NAME_UPPER to a paired
extern/weak pair supplied alongside PDX_TOOL_VERSION); the paired
`VersionBackend::DOC_TOOL_NAME_UPPER` literal tracks the lowercase
mirror at library-ship time to save a per-invocation uppercase
conversion. The legacy `<TOOL> VERSION OK\n` line preserves the
fingerprint several paideia-os smoke drivers already grep for.
The new klog tag for the library-side emit is `pdxargv.version-auto`.

Override mechanism: `VersionBackend::set_override(1)` opts the tool
out. With override set, `parse_argv` stores `--version` as an
ordinary flag and returns `ERR_OK`; the tool dispatches on
`find_flag_by_id(STD_ID_VERSION)` and renders its own text
(useful when a tool wants to include a build-hash or signing-key
fingerprint the library-owned emit does not know about).
`set_override(0)` restores the default; `pdxargv_version_reset()`
(called by `TestHarness::full_reset`) zeroes the flag so each test
starts from the auto-emit default.

Cap posture: the pre-1.2 caps.decl language "performs NO syscalls
of its own" is narrowed to carve out the seven sys_writes
`emit_default` issues on fd 1. Consumers hold the fd-1 cap they
already needed for their own I3 dispatch output; libpdx-argv itself
holds no cap of its own to gate them (the syscall inherits the
caller's cap at the process boundary). Consumers lacking the cap
see EBADF returned by the syscall and the emit path returns anyway
— the auto-emit is best-effort, same silent-write policy the
schema-emit consumer pattern uses.

Files touched:

  - src/version_backend.pdx (NEW)
      module VersionBackend: override_enabled, three literal
      symbols, three .rodata length symbols, four public
      functions (pdxargv_version_reset, set_override,
      version_strlen, emit_default).

  - src/parsed_args.pdx
      +ERR_VERSION_EMITTED = 13.

  - src/parser.pdx
      +--version dispatch after the long-flag and short-flag
      stores (id==2 + override==0 → call emit_default; return
      ERR_VERSION_EMITTED via parse_argv_fail). The existing
      6-push + sub rsp,8 prologue keeps rsp%16 aligned for the
      added nested call.

  - src/std_vocab.pdx
      +docstring note that registering --version via register_all
      opts the tool into the auto-emitter.

  - tests/harness.pdx
      +TestHarness::full_reset now calls pdxargv_version_reset
      alongside the other three resets.

  - tests/parse_std_vocab.pdx
      +run_version_auto_emit (case 3): parse_argv on ["--version"]
      returns ERR_VERSION_EMITTED; error_code records the same.
      +run_version_override  (case 4): after set_override(1), the
      same argv returns ERR_OK and stores --version as an ordinary
      flag.

  - tests/smoke_driver.pdx
      +PDX_TOOL_VERSION stub ("1.2.0-libpdx-smoke\0") so the
      smoke binary links end to end without a per-repo
      constants module. +Case-3/4 dispatch in _start.

  - caps.decl
      +ENH-032 note narrowing the "no syscalls" language.

  - design/architecture.md
      +§12 documenting the version-backend module surface, extern
      symbol, dispatch shape, legacy-fingerprint contract, and
      explicit non-goals. Module-id table for id 5 grows from 2 to
      4 cases.

  - doc/libpdx-argv.pdxdoc
      +STANDARD FLAGS row updated for --version; DIAGNOSTICS gains
      an ERR_VERSION_EMITTED entry; CAPABILITY REQUIREMENTS
      narrowed with the same language as caps.decl.

  - README.md
      +API surface entry for version_backend.pdx; ERR_*
      constants list gains ERR_VERSION_EMITTED (13).

Downstream migration: no existing consumer breaks. A consumer that
already dispatches on `find_flag_by_id(STD_ID_VERSION)` in response
to a real parse error now sees `ERR_VERSION_EMITTED` (13) in
`parse_argv`'s return instead — the existing "if err != ERR_OK"
branch fires. The consumer either treats 13 like ERR_OK (exit 0,
the emit has already happened) or calls `set_override(1)` at
bootstrap to render its own text with the pre-ENH-032 dispatch
unchanged. Six satellite `--version` hand-rollers can retire
their local emit path in the same commit that bumps their
libpdx-argv pin, folding their `PDX_TOOL_VERSION` string into a
per-repo `version_constants.pdx`.

### ENH-031 — `argv[0]`-skip convention: `parse_argv_skipping_zero` helper (Closes #41)

`Parser::parse_argv` has always treated `argv[0]` as a real argv slot
to classify — the `_start` program-name slot every satellite receives
per the frozen `execve` ABI (`design/user/execve-abi.md`) lands in
`pos_ptrs[0]` unless the caller skipped it explicitly. Neither
`README.md` nor `design/architecture.md` had documented the required
skip, and the `paideia-satellites/ls` reference consumer at
`src/argv_surface.pdx:266-268` demonstrated the failure mode by
silently capturing its own program name as `_as_path_ptr`.

Rather than change `parse_argv`'s classification semantics (which
would silently break every non-`_start` caller — the smoke driver,
every schema-record test module, and every fixture whose synthesised
argv does not include a program name), ENH-031 adds a companion entry
point that isolates the `+1`/`-1` offset every `_start` consumer
would otherwise re-implement:

    Parser::parse_argv_skipping_zero(argv, argc) -> u64

Semantics: advance `argv` by one pointer slot (`add rdi, 8`),
decrement `argc` by 1 (`sub rsi, 1`), then forward to `parse_argv`
via a nested `call`. Return value is `parse_argv`'s return value
unchanged. `argc == 0` short-circuits to `parse_argv(argv, 0)`,
which returns `ERR_OK` immediately without dereferencing `argv` (the
loop-head `cmp r13, r12; jge parse_argv_done_ok` fires on the first
iteration), so the wrapper is safe on an empty or nil argv.

Alignment discipline: non-leaf; 1-push (`rbx`, unused) prologue
brings `rsp%16` to 0 for the nested `parse_argv` call — the same
pattern `StdVocab::register_all` uses for its `FlagSpec` calls. `rax`
survives the `pop rbx; ret` epilogue because `rbx` is callee-save
and no instruction between the nested-call return and the epilogue
touches `rax`.

Documentation:

  - `README.md` §parser.pdx table adds a row for the new entry point
    and notes that `parse_argv` remains the lower-level primitive.
  - `README.md` "Bootstrap and parse" example updated to call
    `parse_argv_skipping_zero` with a one-line note showing the
    hand-computed offset alternative.
  - `design/architecture.md` §1 public surface lists both entry
    points; §4 "Parser state machine" gains an "argv[0] convention"
    subsection linking to `design/user/execve-abi.md`.

No existing consumer's behaviour changes — `parse_argv` is untouched.
The new symbol is purely additive; downstream repos that want the
helper adopt it on the same commit that bumps their `libpdx-argv` pin.

## 1.1.0 — 2026-09-02

Post-1.0 enhancement tranche. Groups Wave 1 (`ENH-022` / `ENH-023` /
`ENH-029`, closed earlier this pass) with Wave 2 (`ENH-030`, closed
today) — pulled forward from the deferred post-1.1 slot after
`ENH-030` surfaced as the blocker every downstream P0-tool link hit.
Also folds forward the `ENH-024` (find_flag_by_id 0-skip) and
`ENH-026` (wire ERR_UNKNOWN_ARG_FORM) fixes and the `ENH-012`
witness closure that had been sitting in Unreleased.

Wave grouping (in ENH-order for the SemVer diff table):

  Wave 1 (test/scaffolding — no source ABI change):
    ENH-022 #32  rename test modules to *Tests
    ENH-023 #33  qualify smoke-driver cross-module call sites
    ENH-029 #39  scaffold pkgs/consumers.list

  Wave 2 (source ABI change — cross-module symbol rename):
    ENH-030 #40  rename module-scope colliding exports (reset, register)

  Correctness fixes (behaviour-preserving except case10 regrade):
    ENH-024 #34  find_flag_by_id(0) skips unregistered slots
    ENH-026 #36  wire ERR_UNKNOWN_ARG_FORM (3) real path

  Documentation/witness closures:
    ENH-012 #22  --foo=bar / --foo bar equals-form witness

The 1.1.0 line is the coordination point for downstream repos:
consumers that pinned 1.0.0 keep working; consumers that bump to
1.1.0 update their bare-name call sites to the new mangled
`parsed_args_reset` / `flag_spec_reset` / `flag_spec_register` /
`schema_emit_reset` / `schema_emit_register` names once, and
subsequently link cleanly against every other consumer of the same
library on the same link line — the previous multi-`reset` /
multi-`register` link error is definitively gone.

### ENH-030 — Rename module-scope colliding exports (Closes #40)

Every real consumer of `libpdx-argv` links at least two of
`parsed_args.o`, `flag_spec.o`, `schema_emit.o` on the same link
line. Pre-fix, each of those objects defined a global `reset` (three
strong `T` symbols with the same name), and `flag_spec.o` + `schema_emit.o`
each defined a global `register` (two more). `ld -r libpdx-argv/build-out/{parsed_args,flag_spec,schema_emit}.o`
failed with:

    multiple definition of 'reset';   ... first defined here
    multiple definition of 'register'; ... first defined here

which is exactly what the satellite adoption preflight hit. The
in-tree `tests/harness.pdx::full_reset` also relied on this and
issued three bare `call reset;` instructions — a real bug, because
the linker collapses those three sites onto the single winning
`reset` symbol and only ONE of the three modules ever got its state
cleared per test case (which one depended on link order). Wave 1
worked around this at the test-module boundary but did not touch
the library-side exports; ENH-030 fixes it at the source of the
collision by giving every exported function a per-module prefix:

  ParsedArgs::reset      -> parsed_args_reset
  FlagSpec::reset        -> flag_spec_reset
  FlagSpec::register     -> flag_spec_register
  SchemaEmit::reset      -> schema_emit_reset
  SchemaEmit::register   -> schema_emit_register

The three `reset` / two `register` bodies are byte-identical
across the rename. The internal overflow label in `flag_spec.pdx`
(`register_full`) is also renamed to `flag_spec_register_full` —
that label was already local, so this is defensive against a
future cross-object jump-label collision, not a fix for an
observable one.

Call-site updates (all in-tree; consumers update in their own
repos as they bump their libpdx-argv pin):

  - src/std_vocab.pdx           7× `call register` → `call flag_spec_register`
  - tests/harness.pdx           3× `call reset` → the three explicit `_reset` names
                                (fixes the "only one state actually cleared" bug)
  - tests/schema_emit_tests.pdx `call reset` / `call register` → `call schema_emit_*`
  - tests/parse_typed_args_tests.pdx / parse_grammar_tests.pdx
                                `call register` (3-arg FlagSpec) → `call flag_spec_register`

Post-rename symbol audit:

  $ nm -g build-out/{parsed_args,flag_spec,schema_emit,parser,schema_invoke,std_vocab,typed,help_backend}.o \
      | awk '$2=="T"{print $3}' | sort | uniq -d
  (empty)

Downstream signal that confirms the mangling was planned in
advance: `paideia-satellites/ls/src/argv_surface.pdx:263` already
references `parsed_args_reset` as an unresolved external. With
ENH-030 landed that reference resolves.

### ENH-024 — `find_flag_by_id(0)` skips unregistered slots (Closes #34)

Under permissive mode (`FlagSpec::strict_mode == 0`, the default),
`Parser::parse_argv` stores an unregistered flag with `flag_ids[k] = 0`
(the sentinel `FlagSpec::lookup` returns for `FKIND_UNKNOWN`). The
pre-fix scans in `ParsedArgs::find_flag_by_id`,
`ParsedArgs::find_last_flag_by_id`, and `ParsedArgs::count_flag_by_id`
matched any slot whose id equalled the caller-supplied `rdi` — so
passing `0` returned the unregistered slot's index (or its tally),
contradicting the "passing 0 returns MAX_FLAGS / count of 0" contract
in the finders' own docstrings.

Fix: insert a `cmp rdx, 0; je <skip>` inside every scan loop so an
id==0 slot is never matched, regardless of the caller's target id.
Behaviour is preserved for any legitimate target: id 0 is reserved
as the "unregistered" sentinel in the `FlagSpec` id-space (StdVocab
occupies 1..9; tool-specific ids start at 100), so no registered
flag can have id==0 to be legitimately looked up. Docstrings on all
three functions are updated to explicitly document the skip and
its rationale; the `ERR_UNKNOWN_ARG_FORM` comment in
`src/parsed_args.pdx` is unrelated (see ENH-026 below).

New regression coverage: `tests/parse_grammar_tests.pdx` cases 21-23
(one per finder function; smoke driver wired). Each parses a
mixed argv where a registered flag (`--verbose`, id=6) sits beside
one or more unregistered flags, then asserts the finder returns
the not-found sentinel for target 0 while still resolving the
registered flag correctly.

### ENH-026 — Wire `ERR_UNKNOWN_ARG_FORM` (3) real path (Closes #36)

`ParsedArgs::ERR_UNKNOWN_ARG_FORM = 3` had been declared since M1
but marked "reserved; not currently set". This wave wires a real
firing path in `Parser::parse_argv`: an argv slot is now rejected
with error code 3 (and `error_arg_index = the offending index`)
when it fits neither the flag grammar nor the positional grammar.
Concrete triggers today:

  - empty string `""` argv slot (byte0 == NUL);
  - bare `-` (byte0 == '-', byte1 == NUL).

Bare `--` is UNCHANGED — it remains the M2-003 positional sentinel
(`ddash_seen` is set and every subsequent argv slot goes to
`pos_ptrs` regardless of leading byte). Slots that appear after
`--` are always positional and never reach the malformed
classifier, so an empty `""` or bare `-` AFTER `--` is stored as
a positional (unchanged pre-ENH-026 behaviour).

Behaviour change for bare `-`: pre-ENH-026 `case10` in
`tests/parse_grammar_tests.pdx` documented the fixture as "bare '-'
is positional (matches the stdin convention)". ENH-026 reclassifies
it as malformed. Tools that want the stdin idiom must filter argv
upstream or register a tool-specific short-name for stdin. Case 10
is updated to expect `ERR_UNKNOWN_ARG_FORM` (=3) with
`error_arg_index=0` and `flag_count==pos_count==0`; the module
docstring `.section FLAG GRAMMAR` in `doc/libpdx-argv.pdxdoc`
records the change explicitly.

New regression coverage: `tests/parse_grammar_tests.pdx` case 24
(empty string `""` triggers ERR_UNKNOWN_ARG_FORM). Case 10 is now
also part of the ENH-026 witness set. `doc/libpdx-argv.pdxdoc` §237
is rewritten from "reserved; no code path returns it yet" to the
concrete trigger list, and the README error-code line for code 3 is
updated to name ENH-026.

### ENH-022 — Rename test modules to `*Tests` (Closes #32)

Test-side rename only; no behavior change. Every test module under
`tests/` that previously shared a `PascalCase` name with its production
counterpart under `src/` is renamed to `<Name>Tests` to eliminate the
module-namespace collision:

  - `tests/parse_grammar.pdx`       — `ParseGrammar`       → `ParseGrammarTests`
  - `tests/parse_typed_values.pdx`  — `ParseTypedValues`   → `ParseTypedValuesTests`
  - `tests/parse_typed_args.pdx`    — `ParseTypedArgs`     → `ParseTypedArgsTests`
  - `tests/parse_std_vocab.pdx`     — `ParseStdVocab`      → `ParseStdVocabTests`
  - `tests/parse_schema_record.pdx` — `ParseSchemaRecord`  → `ParseSchemaRecordTests`
  - `tests/help_backend.pdx`        — `HelpBackend`        → `HelpBackendTests`
  - `tests/schema_emit.pdx`         — `SchemaEmit`         → `SchemaEmitTests`

`tests/README.md` §Layout and `design/architecture.md` §11.2 already
carried the `*Tests` names ahead of code (documented in the ENH-022
audit); this change brings the source into line with the docs.
`tests/harness.pdx` (`Harness`) and `tests/smoke_driver.pdx`
(`SmokeDriver`) do not collide and are untouched.

### ENH-023 — Qualify smoke-driver cross-module call sites (Closes #33)

`tests/smoke_driver.pdx` `_start` previously issued ~65 unqualified
`call run_caseN` (and `call run_all_9` / `call run_ids_unique`)
instructions. Six different test modules each declare `pub let
run_case1`, so the calls were ambiguous at link time. Every
cross-module call in the smoke driver is now fully qualified:

  - `call run_case1..20`   → `call ParseGrammarTests::run_case1..20`
  - `call run_case1..24`   → `call ParseTypedValuesTests::run_case1..24`
  - `call run_case1..5`    → `call ParseTypedArgsTests::run_case1..5`
  - `call run_all_9`       → `call ParseStdVocabTests::run_all_9`
  - `call run_ids_unique`  → `call ParseStdVocabTests::run_ids_unique`
  - `call run_case1..10`   → `call ParseSchemaRecordTests::run_case1..10`
  - `call run_case1..3`    → `call HelpBackendTests::run_case1..3`
  - `call run_case1..5`    → `call SchemaEmitTests::run_case1..5`
  - `call reset_tally`     → `call Harness::reset_tally`
  - `call exit`            → `call SysExit::exit`

`SysExit::exit` remains a link-time symbol supplied by the smoke-binary
wiring layer (see ENH-007 / #14). Cross-module unqualified calls that
remain inside individual test-module bodies (`call record_pass`,
`call record_fail`, `call full_reset`, plus src-module calls such as
`call parse_argv` and `call lookup`) are out of scope for this wave
and will be addressed together with the ENH-007 runnable-smoke wiring.

### ENH-029 — Scaffold `pkgs/consumers.list` (Closes #39)

New file `pkgs/consumers.list` enumerates the 6 verified downstream
callers (pkg, ls, cp, mkdir, mv, rm) with per-consumer symbol
summaries. Data is derived from the ENH-011 audit already documented
in `README.md` §Callers; the README §Callers preamble now names
`pkgs/consumers.list` as the authoritative machine-readable source and
declares itself the prose mirror. No downstream consumer is added or
removed by this change.

### ENH-012 — `--foo=bar` / `--foo bar` equals-form witness (Closes #22)

Documentation-only. The long-flag grammar has accepted both
`--foo bar` (space) and `--foo=bar` (equals) since M1-001; the
`:` separator was added at M2-003 as an equivalent universal.
Case2 (`--color=auto`) and case3 (`--no-cap:KIND_TTY`) in
`tests/parse_grammar.pdx` have covered both forms since M4-001.
This entry closes ENH-012 as an already-implemented witness — no
behavior change. The README §parser.pdx paragraph explicitly
lists all four accepted forms (`--foo`, `--foo=bar`, `--foo:bar`,
`--foo bar`); no code change was needed. The Q1-locked decision
(accept both forms) matches shipped behavior.

## 1.0.0 — 2026-08-22

First signed release. Closes the R49 shared-library slot for CLI
argument parsing. All five milestones M1–M5 have landed and every
milestone issue (#1–#10 in `paideia-os/libpdx-argv`) is closed.

### Public surface

- `ParsedArgs` — the in-memory record every consumer reads after
  `parse_argv` returns (long-flag, short-flag, positional, typed
  slots; error-code constants for tool-side diagnostics).
- `Parser::parse_argv(argv_ptr, argc) -> u64` — the primary
  argv-input entry point (M1, M2).
- `FlagSpec::register(name_ptr, kind, id)` /
  `FlagSpec::reset()` — declarative flag registration (M2-001).
- `StdVocab::register_all()` — the I3 9-flag standard vocabulary
  (`--help`, `--version`, `--dry-run`, `--json`, `--schema`,
  `--verbose`, `--quiet`, `--color=`, `--no-cap:`; M2-002).
- `Typed::parse_int_u64` / `Typed::parse_size` /
  `Typed::parse_timespan` — typed-flag argument decoders (M2-001).
- `SchemaInvoke::parse_from_schema_record(rec_ptr, rec_len) -> u64`
  — alternate invocation via a `PdxArgvRecord@0.1`
  semantic-pipe wire form; converges on the same `ParsedArgs`
  (M3-001).
- `HelpBackend::fill_doc_argv(argv_slots, tool_name_ptr)` —
  `--help` back-end that synthesises argv for `doc <tool>`
  (M3-002).
- `SchemaEmit::register(schema_name_ptr)` /
  `SchemaEmit::get_count` / `SchemaEmit::get_name` —
  `--schema` declared-output-schema registry (M3-003).

### Wire schemas declared

- `PdxArgvParsed@0.1` — emitted when consumer opts into
  `--pdx-schema` (structured mirror of `ParsedArgs`; used by
  downstream tools that want to introspect a peer tool's parsed
  invocation without re-running the parser).
  **Correction (2026-08-25, `libpdx-argv.ENH-003`):** this schema was
  never implemented — `--pdx-schema` only ever set the `emit_schema`
  bit; no function in this repo has ever serialized `ParsedArgs` into
  this shape. Withdrawn from `caps.decl`/`pkgs/mirror.entry` rather
  than built, since no consumer depended on it. Left in place here
  rather than edited, per this repo's policy of not rewriting a
  signed release's history silently.
- `PdxArgvRecord@0.1` — the alternate-invocation wire form
  consumed by `SchemaInvoke::parse_from_schema_record`
  (schema-driven arg binding when libpdx-argv is called through
  a semantic pipe rather than through argv). **Note (ENH-003):** this
  is this library's *input* schema (`SchemaInvoke` decodes it; nothing
  here encodes it) — `declares_output_schemas:` was the wrong
  direction for it from the start; see `caps.decl`'s
  `consumes_input_schemas:` for the corrected framing.

Both schemas live in the same fingerprint namespace and bind to
`libpdx-semantic-pipe` M2 envelope framing (schema-registry-aware
binding, `libpdx-semantic-pipe.M3-001`).

### Capabilities requested

None. libpdx-argv is a pure userspace library; it makes no
syscalls of its own (see `caps.decl` in this repo). Consumers
declare their own caps.

### Cross-repo relationships (at 1.0)

- Consumers (direct): `pkg`, `shell`, `doc`, `ls`, `cat`, `cp`,
  `mv`, `rm`, `mkdir` (all nine R49+R50 P0 tools).
  **Correction (2026-08-25, `libpdx-argv.ENH-011`):** this overclaimed.
  A source-grep audit found only 6 of these 9 (`pkg`, `ls`, `cp`,
  `mkdir`, `mv`, `rm`) actually call into this library; `cat`, `doc`
  and `shell` do not, each for the reason recorded in README.md
  §Callers. Left in place rather than edited, per this repo's policy
  of not rewriting a signed release's history silently.
- Coordinated wire schema (shape only, no link):
  `libpdx-semantic-pipe` at M2 envelope framing.
- Runtime target: `doc` at ≥ M2 (`HelpBackend::fill_doc_argv`
  synthesises argv for `doc <tool>`).

### Milestone rollup

| ID              | Title                                                                                   | Issue | Landed at |
|-----------------|-----------------------------------------------------------------------------------------|-------|-----------|
| M1-001          | scaffold + ParsedArgs struct + long-flag grammar (`--foo bar` / `--foo=bar`)            | #1    | 2026-08-21 |
| M1-002          | short-flag grammar one-per-hyphen (clustered → reject, per D3)                          | #2    | 2026-08-21 |
| M2-001          | typed flag arguments (`--older-than 7d`, `--size > 1MB`)                                | #3    | 2026-08-21 |
| M2-002          | 9-flag standard vocabulary from I3                                                      | #4    | 2026-08-21 |
| M2-003          | positional-argument list handling (`--` sentinel, `:` separator)                        | #5    | 2026-08-21 |
| M3-001          | alternate invocation: typed schema record → ParsedArgs                                  | #6    | 2026-08-21 |
| M3-002          | `--help` back-end integration with `doc <tool>`                                         | #7    | 2026-08-21 |
| M3-003          | `--schema` prints tool's declared output schemas                                        | #8    | 2026-08-21 |
| M4-001          | parse-correctness matrix + clustered-short rejection + typed diagnostics + `--help` RT  | #9    | 2026-08-22 |
| M5-001          | dual-signed release + `.pdxdoc` + mirror push                                            | #10   | 2026-08-22 |

### Signing state at 1.0

`manifest.pdxsig` in this release contains the payload
(`name=libpdx-argv`, `version=1.0.0`, `source_tree_sha256`, the
per-file `sources` array, the `declared_output_schemas` block,
and the `deps` block) plus two ML-DSA-65 signature slots:

- `author_pk = paideia-os-team` — signed with the R49 author key
  once the paideia-as v0.33-crypto-kdf toolchain and the
  `paideia-as release --sign` subcommand are reachable from the
  release-runner host. Until then the slot carries the string
  `PENDING:paideia-os-team-key@v0.33` and `pkg install --strict`
  will refuse the package (as designed — I5.a).
- `paideia_root_pk` — the R32-mint countersignature applied by
  `pkgs.paideia-os` at admission time. Until the pkgs.paideia-os
  mirror lands (paideia-os meta issue `T-INFRA-001`), the slot
  carries the string `PENDING:paideia_root_pk@R32-mint`.

Both slots are populated in the same release-runner pass that
first signs and then admits to the mirror; the on-disk shape
above is what gets replaced in place. Neither placeholder is a
valid ML-DSA-65 signature; both are text sentinels of the exact
length + form the pkg-install verifier looks for, so a `pkg
install` under `--strict` fails cleanly at "signature not
present" rather than at "signature malformed". See §11.2 of
`design/user/model.md` for the verify path.

### Notes

- No API breaks planned before 2.0. The `PdxArgvRecord@0.1`
  wire form is versioned; a `@0.2` may add fields (backward
  compatible per `libpdx-semantic-pipe.M3-002` version-tolerance
  rules).
- The M4 smoke driver is not shipped in the binary package;
  `tests/*.pdx` stay in-tree only.
