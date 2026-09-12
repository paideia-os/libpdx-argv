# libpdx-argv — CHANGELOG

All notable changes to `libpdx-argv` are recorded here. The format is
loosely modelled on Keep-a-Changelog, adapted to the PaideiaOS milestone
rubric in `design/tooling/r49-r50-plan.md` §5.

## Unreleased

### ENH-017 hotfix — `MAX_COLLECTED_ERRORS` overflow-cap test coverage (Closes #44)

`Parser::parse_argv_ex` under `ARGV_COLLECT_ALL_ERRORS` caps the
error ring at `MAX_COLLECTED_ERRORS` (16) via a single branch in
`parse_argv_maybe_collect`:

    lea r11, [rip + error_ring_count];
    mov rcx, [r11];
    cmp rcx, 16;                        // MAX_COLLECTED_ERRORS
    jge parse_argv_maybe_collect_gate;  // skip store AND increment
    ...store into ring[rcx]...
    add rcx, 1;
    ...write back error_ring_count...

The gate is correct — the `jge` skips both the ring store and the
count increment, so the 17th (and beyond) recoverable fail is
silently dropped while the ring keeps its first 16 records
intact. `error_count()` docstring states "reports
MAX_COLLECTED_ERRORS on overflow", and `Parser::parse_argv_ex`
carries the same claim in its own justification. Pre-hotfix,
however, the whole cap surface was documentation-only at runtime:
`tests/parse_grammar_tests.pdx` case 35 (the only exercise of the
collect-all ring) drove exactly two accumulated errors, so a
refactor that flipped the gate direction (`jge` → `jg`), moved
the `add rcx, 1` above the gate, or dropped the gate entirely
would land silently. `parse_argv_fail_append`'s parallel `cmp
rcx, 16; jge parse_argv_epilogue` is also uncovered but does not
change any caller-visible observable beyond the ring itself, so
it is left to a future case.

Fix (test-only; no source change — the cap logic is correct as
shipped):

- `tests/parse_grammar_tests.pdx`: new `run_case36`. Fixture
  drives 17 argv slots all pointing to the same `"--zog\0"`
  string under `FlagSpec::set_strict(1)` with no register call
  for `zog`. Every iteration fires `ERR_UNKNOWN_FLAG` (12) via
  the ENH-004 strict-mode lookup-miss path BEFORE any store into
  `flag_ids`/`flag_kinds`, so the test does not collide with the
  `MAX_FLAGS=32` gate; the only observable is the ring itself.
  `parse_argv_ex(argv, 17, ARGV_COLLECT_ALL_ERRORS)` returns 12
  (first-error preservation via `parse_argv_epilogue`'s ring[0]
  read); assertions cover `error_count() == 16` (not 17, not
  15), `error_at(0) == (12, 0)` (first-error snapshot),
  `error_at(15) == (12, 15)` (16th slot correctly holds the 16th
  error — witnesses that the gate skips the STORE, not just the
  increment), `error_at(16) == (0, 0)` (OOB sentinel per the
  `error_at` docstring), and the scalar `error_code` /
  `error_arg_index` slots preserved at `(12, 0)`. Fail tag
  `0x100000024 = (1<<32) | 36`.
- `tests/smoke_driver.pdx`: dispatch `run_case36` immediately
  after `run_case35`.

Failure taxonomy: no dedicated overflow error code exists in the
`ERR_*` table (0..20) and none is added — the cap is a silent
drop by design (the return value carries the first error's code
per the "first error wins" contract, unchanged whether the ring
overflowed or not; `error_count()` distinguishes overflow vs.
non-overflow via the equality-with-`MAX_COLLECTED_ERRORS` check
callers already own).

Impact: no runtime behavior change. Discovered by W44 pre-commit
debugger sweep, 2026-09-11; hotfixed 2026-09-12.

### ENH-019 hotfix — `register_string_enum` null-page-read defence (Closes #45)

Pre-hotfix `FlagSpec::register_string_enum` stored the caller's
`(allowed_ptr, allowed_count)` pair verbatim. A caller passing
`allowed_ptr == 0` with `allowed_count > 0` (a contract violation)
passed the SPEC_MAX gate and the subsequent `Parser::parse_argv_ex`
enum walk dereferenced address 0 at
`mov r8, [r11]; mov rdi, [r8 + r9*8]` — a null-page read that
page-faults on paideia-os and clobbers whatever sits at 0 in a hosted
target. The mirror shape `allowed_ptr != 0 && allowed_count == 0`
was safe (the count-check sentinel already disabled the gate) but
still a caller-intent mistake worth flagging.

Fix (defence in depth, no signature change):

- `src/flag_spec.pdx`: `register_string_enum` now prepends an
  invariant check on `(allowed_ptr, allowed_count)`. Both
  incoherent shapes coerce to `(0, 0)` via `xor rdx,rdx / xor
  rcx,rcx` before the store — the parser's own `cmp count, 0; je
  skip_str_enum` gate then short-circuits and never dereferences
  the null pointer. `ERR_INVALID_ENUM_SPEC` (20) is published into
  a new companion `.bss` slot `last_register_error` so a
  defence-in-depth caller can `cmp last_register_error, 0` after
  every `register_string_enum` and refuse to proceed on nonzero.
  The success path also writes 0 to the slot so "last call
  wins" semantics stay accurate without an intervening reset.
- `src/flag_spec.pdx`: new `pub let mut last_register_error : u64`
  companion slot; `flag_spec_reset` extended to zero it (same
  discipline as `strict_mode` / `subcommand_table_ptr` /
  `subcommand_table_count`).
- `src/parsed_args.pdx`: new `ERR_INVALID_ENUM_SPEC : u64 = 20`
  constant. Not written by any `parse_argv*` path — it is a
  registration-time diagnostic only, published into
  `FlagSpec::last_register_error`, so a consumer's existing
  `if err != ERR_OK { … }` branch on a `parse_argv*` return
  never observes it.
- `tests/parse_typed_values_tests.pdx`: new `run_case35`
  (security-relevant shape `(ptr=0, count=1)` → `last_register_error
  == 20`, subsequent parse safe with `ERR_OK`), `run_case36`
  (mirror `(ptr!=0, count=0)` → same diagnostic + safe parse),
  and `run_case37` (legal shape → `last_register_error == 0`,
  proving the success path clears the slot). All three follow the
  case-30 pattern (`full_reset` first, `record_pass`/`record_fail`
  under standard tags 0x200000023 / 0x200000024 / 0x200000025).
- `tests/smoke_driver.pdx`: dispatch the three new cases after
  `run_case34`.

Impact: caller-contract-violation only (attacker-controlled data
cannot reach `register_string_enum`'s arguments via wire input on
any current consumer), so the pre-hotfix severity was low; the
hotfix eliminates the null-deref regardless of caller vigilance and
gives defence-in-depth callers a discoverable diagnostic. The
`register_*` family's "silent, never fails hard" invariant is
preserved: the coercion still registers the flag as a plain
`FKIND_STR` (with the gate disabled), so a caller that ignores
`last_register_error` sees safe fallback rather than a failed
registration. Discovered by W45 retrospective debugger sweep,
2026-09-11.

### ENH-007 — Runnable smoke: SysExit wiring + `tools/run-tests.sh` (Closes #14)

Pre-ENH-007 the "M4-001 50/50 green" claim recorded throughout
this repo was a claim that every `.pdx` file **assembled cleanly**,
not that any test assertion **executed**. `tools/build.sh` (the
only runner) counted paideia-as encoder failures per file and never
proceeded to link. `tests/smoke_driver.pdx` ended in
`call SysExit::exit;` targeting an undefined extern that no wiring
in this repo supplied — the driver could not have run even if a
downstream had chosen to boot the objects. See `STATUS.md`
§"Runnable smoke wiring" for the plainly-stated provenance.

ENH-007 lands the wiring in-repo (rather than waiting on `pkg.M4`
per the M4→M5 chain in `design/tooling/r49-r50-plan.md` §5.12):

- `tests/sys_exit_shim.pdx` — new. `SysExitShim` module with a
  single `pub let exit : (u64) -> () !{sysreg} @{}` function that
  emits `mov rax, 60; syscall;` (SC+ ID 60 = sys_exit, both
  paideia-os and Linux). The elaborator flattens `SysExit::exit`
  path references to the last segment (`exit`) — see
  `paideia-as::parse_stmt::try_extract_symbol_name` (issue #1319) —
  so the shim's module basename (`SysExitShim`) is linker-invisible;
  only the `exit` symbol needs to be present at link time.
- `tools/tests-link.ld` — new. Flat-ELF linker script mirroring
  mkfs.pdxfs's `link.ld` (paideia-os #1976): `ENTRY(_start)`,
  .text at 0x00400000, .data at 0x00600000, .bss contiguous with
  .data. Both paideia-os and Linux accept this exact layout.
- `tools/run-tests.sh` — new. Assemble + link + exec + decode.
  Uses `python3`'s `os.waitid` to recover the full 32-bit
  `si_status` (shell `$?` clamps to the low 8 bits); decodes
  `(pass_count << 16) | fail_count` per the smoke driver's
  contract. Prints `PDXARGV SMOKE OK` on all-green,
  `PDXARGV SMOKE FAIL` otherwise. Wrapper exit codes: 0 clean,
  1 build fail, 2 link fail, 3 smoke fail, 4 signalled,
  5 prereq missing.
- `tests/README.md` — new "Running the smoke" section
  documenting the wrapper's invocation, exit-code table, and
  the known link-stage hazard (below).
- `design/architecture.md` §11.4 — updated to reference the
  in-repo wiring and cross-link `STATUS.md`.

**Host or QEMU?** Host. paideia-os's SC+ numbering was chosen at
R17-m1-001 to co-opt the Linux syscall table (SC+ ID 60 = Linux
syscall 60 = sys_exit; SC+ ID 1 = sys_write, the only other
syscall this repo issues), so a linked `.pdx` smoke ELF is
directly host-runnable on a developer Linux box with no QEMU and
no paideia-os kernel dependency.

**Exit-code contract.** The smoke driver packs
`(pass_count << 16) | fail_count` into `rdi` before calling
`SysExit::exit`. The kernel preserves the full 32-bit int in
`si_status` (reachable via `os.waitid`); shell `$?` reflects only
the low 8 bits, which for a 50-case matrix comfortably captures
`fail_count` — so `$? == 0` on all-green is a reliable pass/fail
signal even without the python3 helper.

**Fingerprint (from #14).** `bash tools/run-tests.sh` prints
`PDXARGV SMOKE OK` and exits 0 on a clean tree; the tally decodes
to pass=50 fail=0. Deliberately breaking one assertion in
`tests/parse_grammar_tests.pdx` prints `PDXARGV SMOKE FAIL` with
non-zero low-16 and a `last_fail_tag` whose high dword is 1.

**Known outstanding — link-stage duplicate-symbol collisions.**
Every test module currently exports `run_case1`, `run_case2`, ...
as bare flat linker symbols (paideia-as elaborator flattens
`Module::fn` to the last segment — see
`parse_stmt::try_extract_symbol_name`, issue #1319). Six of the
seven test modules define `run_case1`, so `ld -z defs` (the
correct default, kept by this runner) refuses the link with
`multiple definition of run_case1`. `tools/run-tests.sh` surfaces
this categorically (exit 2 + diagnostic) rather than papering over
it with `--allow-multiple-definition` (which would silently pick
the first definition and let each `run_case1` run only once — the
smoke would falsely report green). Resolutions:

1. **Preferred** — land Module::fn symbol mangling in paideia-as
   (benefits every satellite repo and closes the general design
   gap; issue #1319 already tracks the discussion).
2. **In-repo workaround** — rename every test case symbol to
   `<module>_<case>` shape (e.g. `parse_grammar_run_case1`) and
   update `tests/smoke_driver.pdx` to call the mangled names.
   Touches every test file but unblocks execution today.

The ENH-007 landing intentionally does NOT choose between these —
the wiring is the deliverable; the naming choice belongs on a
follow-up ticket (either paideia-as or a libpdx-argv ENH depending
on which resolution is picked).

### ENH-006 — Caller-owned `ParsedArgsCtx` multi-parse contexts (Closes #17)

Pre-ENH-006 every ParsedArgs, FlagSpec and SchemaEmit slot lived in
`.bss` singletons — one live parse per process. That was the right
bootstrap call and it is still right as the default, but it was the
one genuine library-side reason a tool could not adopt libpdx-argv:
`shell` parses many command lines per process and therefore built
its own `Pds` (a reimplementation forced by the storage model, not a
rejection of the design); subshells, `mux` splits and `pkg`'s
subcommand re-parse all want the same thing. Two of the repo's own
documents (`design/architecture.md` §3 and
`src/parsed_args.pdx:32`) had also been claiming for two releases
that "M4 introduces a caller-owned struct" — a promise M4 never
delivered; ENH-006 lands the deliverable and rewrites both to
reflect that.

Public surface additions (additive-only; every existing consumer
sees zero behaviour change through the singleton entry points):

  - `ParsedArgs::ParsedArgsCtx` — caller-allocated `[u64; 168]`
    block @align(8) (1344 bytes = `PA_CTX_SIZE`; 168 qwords =
    `PA_CTX_QWORDS`) that mirrors the 13 per-parse singleton
    slots. Layout via `PA_CTX_OFF_*` byte-offset constants:
    `FLAG_NAMES=0`, `FLAG_VALUES=256`, `FLAG_COUNT=512`,
    `POS_PTRS=520`, `POS_COUNT=776`, `ERROR_CODE=784`,
    `ERROR_ARG_INDEX=792`, `EMIT_SCHEMA=800`, `FLAG_IDS=808`,
    `FLAG_KINDS=1064`, `DDASH_SEEN=1320`,
    `DDASH_ARG_INDEX=1328`, `SUBCOMMAND_ID=1336`. The ENH-017
    error_ring stays singleton-only (a caller who wants both
    collect-all mode and multi-parse walks the singleton ring
    immediately after each `parse_argv_ctx`).
  - `Parser::parse_argv_ctx(ctx_ptr, argv, argc) -> u64` —
    caller-owned wrapper around `parse_argv`. Internally resets
    the singleton (implicit reset so the multi-parse idiom
    needs no bookkeeping dance between successive calls), runs
    `parse_argv`, then snapshots the singleton state into the
    caller's ctx block via `ParsedArgs::pa_ctx_snapshot`.
    Return value = the parse error code (also mirrored into
    `ctx.error_code`).
  - `SchemaInvoke::parse_from_schema_record_ctx(ctx_ptr,
    rec_ptr, rec_len) -> u64` — sibling for the schema-record
    invocation path. Same snapshot-after design.
  - `ParsedArgs::reset_ctx(ctx_ptr) -> ()` — zero the 8
    bookkeeping slots (flag_count / pos_count / error_code /
    error_arg_index / emit_schema / ddash_seen /
    ddash_arg_index / subcommand_id) inside a caller-owned ctx.
    The singleton is untouched.
  - `ParsedArgs::find_flag_by_id_ctx(ctx_ptr, id) -> u64` —
    ctx-relative twin of `find_flag_by_id`. Scans
    `ctx.flag_ids` up to `ctx.flag_count`; returns slot index
    or `MAX_FLAGS` (=32). Preserves the ENH-024 id==0 skip.
  - `ParsedArgs::pa_ctx_snapshot(ctx_ptr) -> ()` — copies the
    13 per-parse slots from the singleton into the caller's
    ctx block. Called internally by the two `parse_..._ctx`
    entry points; also public so a caller who ran a plain
    `parse_argv` can capture that result into a ctx for later
    `find_flag_by_id_ctx` reads.
  - `ParsedArgs::pa_ctx_copy_qwords(dst, src, n) -> ()` —
    internal qword-copy helper used by `pa_ctx_snapshot` AND
    by the FlagSpec save/load pair (below).
  - `FlagSpec::FlagSpecCtx` — caller-allocated `[u64; 295]`
    block @align(8) (2360 bytes = `FS_CTX_SIZE`; 295 qwords =
    `FS_CTX_QWORDS`) that mirrors the 16 FlagSpec slot-groups.
    Layout via `FS_CTX_OFF_*` constants (see
    `src/flag_spec.pdx` for the full field list).
  - `FlagSpec::flag_spec_save_ctx(ctx_ptr) -> ()` — snapshot
    the entire FlagSpec singleton (10 arrays × 32 qwords + 6
    scalars) into a caller-owned block.
  - `FlagSpec::flag_spec_load_ctx(ctx_ptr) -> ()` — inverse of
    the save: copy every field FROM the ctx block INTO the
    FlagSpec singleton.
  - `FlagSpec::flag_spec_reset_ctx(ctx_ptr) -> ()` — zero the
    4 bookkeeping slots inside a caller-owned FlagSpecCtx.

`FlagSpec` uses a save/load swap pattern rather than duplicating
every per-entry registration function as a `_ctx` variant. A
caller that wants git-vs-mercurial FlagSpec independence swaps the
whole registration set with two calls (load target, do work, save
target); a future ENH-047 may add per-entry `_ctx` variants
(`flag_spec_register_ctx`, `lookup_ctx`, …) if the swap overhead
ever measures as prohibitive.

`SchemaEmit` stays singleton (per-tool state, one live tool per
process) — the same rationale that keeps it singleton in the pre-
ENH-006 shape.

Additive-only mechanism. The `_ctx` wrappers do NOT rewrite the
parser to use ctx-relative addressing (that would be a ~1600-line
internal change with no consumer benefit). Instead the underlying
parser writes to the singleton exactly as it always has, and the
wrapper snapshots the 13 fields into the caller's ctx block via
`pa_ctx_snapshot`. Two consecutive `parse_argv_ctx(&a, …)` /
`parse_argv_ctx(&b, …)` calls then leave both ctx blocks with
byte-independent results — the multi-parse fingerprint the ENH-006
issue text specifies. Every existing consumer (`cp`, `ls`,
`mkdir`, `mv`, `pkg`, `rm`, every schema-record test, every
satellite) sees byte-identical behaviour through the unchanged
singleton entry points.

Test coverage:

  - New module `tests/multi_context.pdx` (module `MultiContext`,
    module id 9 in the harness — previously reserved for
    parse_mixed) with three cases wired into
    `tests/smoke_driver.pdx`:
    - case1: two contexts, two `parse_argv_ctx` calls, verify
      no cross-talk via `find_flag_by_id_ctx` (HELP reachable
      only via ctx_a, JSON only via ctx_b), and correct per-ctx
      `flag_count` / `pos_count`.
    - case2: re-read `ctx_a` after `ctx_b`'s parse — must be
      unchanged (regression witness for a snapshot-clobber
      that would silently corrupt an earlier ctx).
    - case3: `reset_ctx(&ctx_a)` isolation — ctx_a bookkeeping
      zeroed, `ctx_b` untouched.
  - `tests/README.md` module-id table updated (row 9:
    `ParseMultiContext`, 3 cases); non-goals section rewritten
    to reflect the sequential-multi-parse coverage.

Documentation:

  - `design/architecture.md` §3 rewritten. New §3.1 (ENH-006
    storage model — caller-owned ParsedArgsCtx) documents the
    layout, entry points, snapshot-after mechanism, FlagSpec
    save/load pattern, and the concurrency posture (paideia-os
    is single-threaded, so the coexistence issue that motivated
    ENH-006 is sequential). §1 comment updated so the two
    stale-M4 promises no longer contradict what shipped.
  - `README.md` — new "ParsedArgsCtx — caller-owned multi-parse
    contexts" subsection under `ParsedArgs`; new rows in the
    Parser, SchemaInvoke, and FlagSpec tables for
    `parse_argv_ctx`, `parse_from_schema_record_ctx`,
    `find_flag_by_id_ctx`, `reset_ctx`, `pa_ctx_snapshot`,
    `pa_ctx_copy_qwords`, `flag_spec_save_ctx`,
    `flag_spec_load_ctx`, `flag_spec_reset_ctx`.
  - `doc/libpdx-argv.pdxdoc` — new SYNOPSIS block for the
    multi-parse idiom; new HISTORY row describing the
    surface delta.
  - `src/parsed_args.pdx` header comment updated so it no
    longer claims M4 delivered the caller-owned variant.

Compliance notes (paideia-as 0.36+):

  - Every new `pub let :sig = fn ...` carries `capabilities:
    {}` per the paideia-as 0.36 requirement.
  - Unsafe-bodied lambda parameter counts: `parse_argv_ctx` and
    `parse_from_schema_record_ctx` take 3 params (ctx + 2);
    `flag_spec_save_ctx` / `load_ctx` / `reset_ctx` /
    `pa_ctx_snapshot` / `reset_ctx` (ParsedArgs) take 1;
    `pa_ctx_copy_qwords` takes 3; `find_flag_by_id_ctx` takes 2.
    All well under the B1708 6-param cap.
  - No `test rN,rN`, no `and reg,imm64`, no 2-op `imul`, no
    scaled `[reg + N*8]` (register-scaled `[reg + rcx*8]` is
    the only form used, which is inside the R49 encoder
    subset). PascalCase basenames for the new test module
    (`ParseMultiContext`). All labels in the new code are
    `mc_*` / `pactx_*` / `ffbic_*` / `pacpq_*` prefixed —
    none collide with reserved words.
  - SysV push/pop alignment preserved at every nested call:
    `parse_argv_ctx` and `parse_from_schema_record_ctx` use a
    2-push + `sub rsp, 8` prologue (24 B on stack after ret
    addr → rsp%16 = 0); the snapshot / save / load helpers
    use a 1-push (rbx) prologue (8 B → rsp%16 = 0).

### ENH-020 — Git-shape subcommand dispatch (Closes #30)

Pre-ENH-020 every tool was a single flat command: `pkg install …`,
`mkfs.pdxfs create …`, and the like all had to hand-roll their
own "argv[1] switch" before calling `parse_argv`, and the library
had no way to know that `--message` was scoped to the `commit`
sub rather than the top-level parse. ENH-020 lifts git-shape
subcommand dispatch into `Parser::parse_argv_ex` (§19 of
`design/architecture.md`): the caller registers a `SubSpec`
table once at bootstrap, and the parser inline-dispatches to the
matching sub's `flag_specs` array before the main argv walk
starts.

Public surface additions:

  - `FlagSpec::register_subcommands(table_ptr, count) -> ()` —
    leaf; the single install path. Publishes into the singleton
    `subcommand_table_ptr` / `subcommand_table_count` slots that
    `Parser::parse_argv_ex` reads at the top of its walk. `count ==
    0` OR `table_ptr == 0` is the "disable dispatch" spelling.
  - `FlagSpec::subcommand_table_ptr : u64` and
    `FlagSpec::subcommand_table_count : u64` — the .bss slots
    holding the caller-installed pair. Zeroed by
    `flag_spec_reset` so a fixture that installed a table in one
    case never leaks it into the next.
  - `FlagSpec::SUBSPEC_OFF_NAME` (= 0), `SUBSPEC_OFF_ID` (= 8),
    `SUBSPEC_OFF_FLAG_SPECS` (= 16), `SUBSPEC_OFF_FLAG_COUNT`
    (= 24), `SUBSPEC_OFF_HELP` (= 32), `SUBSPEC_STRIDE` (= 40) —
    symbolic byte offsets for the 40-byte `SubSpec` entry the
    caller-owned table is an array of.
  - `FlagSpec::SUBFLAGSPEC_OFF_NAME` (= 0),
    `SUBFLAGSPEC_OFF_KIND` (= 8), `SUBFLAGSPEC_OFF_ID` (= 16),
    `SUBFLAGSPEC_STRIDE` (= 24) — symbolic byte offsets for the
    24-byte `SubFlagSpec` entry each `SubSpec.flag_specs_ptr`
    points at.
  - `ParsedArgs::subcommand_id : u64` — the id of the
    dispatched sub, or `0` if no dispatch happened (either no
    table installed OR argv[1] was flag-shaped / empty /
    absent). Zeroed by `parsed_args_reset`.
  - `ParsedArgs::ERR_UNKNOWN_SUBCOMMAND : u64 = 19` — set by
    the parser when a sub table is installed AND argv[1] is a
    plausible non-flag non-empty candidate that matches no
    `SubSpec.name`.

Byte layouts:

  - **`SubSpec` (40 bytes, aligned 8)**: `{name_ptr: u64, id:
    u64, flag_specs_ptr: u64, flag_count: u64, help_ptr: u64}`.
    The `help_ptr` slot is reserved for a follow-on
    `sub --help` traversal; the ENH-020 parser dispatch does
    not consult it.
  - **`SubFlagSpec` (24 bytes, aligned 8)**: `{name_ptr: u64,
    kind: u64, id: u64}` — mirrors `flag_spec_register`'s
    3-arg surface exactly. Wider variants (sep-required, INT
    range, STR enum) are a follow-on ENH.

Parser changes (`src/parser.pdx`):

  - Pre-loop dispatch phase in `parse_argv_ex`, gated on
    `FlagSpec::subcommand_table_ptr != 0`. When installed:
    skips argv[0] as program name (r13 starts at 1 by
    default); classifies argv[1]; if flag-shaped, empty, or
    absent → stay with top-level FlagSpec intact (StdVocab
    precedence); if a non-flag non-empty candidate matches
    a `SubSpec.name` → publish `SubSpec.id` into
    `subcommand_id`, hoist `flag_specs_ptr` / `flag_count`
    into callee-save r14/r15, call `flag_spec_reset`, walk
    the flag_specs array calling `flag_spec_register(name,
    kind, id)` per entry, start main loop at r13 = 2;
    non-match → `ERR_UNKNOWN_SUBCOMMAND` via
    `parse_argv_fail` (hard-stop).
  - `parse_argv_sub_scan_head` / `parse_argv_sub_strcmp_head`
    / `parse_argv_sub_match` / `parse_argv_sub_reg_head` /
    `parse_argv_sub_unknown` — new labels inside the
    `parse_argv_ex` body. No changes to `parse_argv` (the
    thin wrapper), `parse_argv_skipping_zero`, or the main
    loop labels; the dispatch phase runs strictly before
    `parse_argv_loop_head`.
  - The 6-push + `sub rsp, 8` prologue keeps `rsp%16 = 0`
    across the added `flag_spec_reset` and
    `flag_spec_register` nested calls. Both callees preserve
    r13/r14/r15 (SysV callee-save) and only clobber
    rax/rcx/r11, so no stack spill of loop state is needed.

Semantics summary:

  - **StdVocab precedence.** A flag-shaped argv[1] (byte 0 ==
    `'-'`) skips the sub table walk, so `git --version` still
    triggers the StdVocab `--version` auto-emit (ENH-032)
    with the top-level FlagSpec intact. Symmetrically for
    `git --help` under ENH-014. A tool wanting sub-specific
    `--version` registers it inside the sub's `flag_specs`
    with its own handler id; the dispatch fires because
    argv[1]=`commit` is not flag-shaped, and the sub's install
    replaces the top-level's including any StdVocab binding.
  - **Argv[0] skip.** When a sub table is installed, argv[0]
    is always skipped (r13 starts at 1). This matches
    `parse_argv_skipping_zero`'s discipline and reflects the
    git-shape convention where argv[0] is the program name.
    Callers that never install a sub table see the pre-ENH-020
    behavior where argv[0] is an ordinary token (r13 starts
    at 0) — the two shapes coexist gracefully because the
    dispatch phase's null-pointer short-circuit runs before
    the `r13 = 1` assignment.
  - **Hard-stop on unknown subcommand.** The fail routes to
    `parse_argv_fail`, not `parse_argv_maybe_collect`,
    because no ParsedArgs storage was attempted at the fail
    site and no coherent advance-past recovery exists (the
    flag_spec table for `argv[2..]` was never installed).
    A collect-all consumer sees `ERR_UNKNOWN_SUBCOMMAND` as
    the terminal reason in `error_ring[0]`.
  - **No partial FlagSpec commit.** The `flag_spec_reset` +
    sub install block runs only on the match path; the
    unknown-subcommand fail happens BEFORE that block, so a
    caller's post-parse FlagSpec inspection sees the
    top-level table intact. This mirrors ENH-013's cluster-
    with-arity discipline (no partial ParsedArgs storage on
    that fail either).
  - **Reset lifecycle.** `flag_spec_reset` zeroes both
    subcommand table slots, so a test fixture that installed
    a table in one case never leaks it into the next — the
    caller re-installs each parse via `register_subcommands`,
    matching the existing per-parse re-registration
    discipline for FlagSpec itself. `parsed_args_reset`
    zeroes `subcommand_id` so the "no dispatch → 0"
    sentinel is honored on every parse.

Fingerprint (issue #30) — the `tests/parse_subcommands.pdx`
cases 1-6 are the regression fixtures:

  With `register_subcommands(&sub_table, 2)` where
  `sub_table[0] = {name="commit", id=1, flag_specs=[{name=
  "message", kind=FKIND_STR, id=200}], flag_count=1,
  help_ptr=&help_commit}` and `sub_table[1] = {name="push",
  id=2, flag_specs=[{name="force", kind=FKIND_BOOL,
  id=201}], flag_count=1, help_ptr=&help_push}`:

    - `parse_argv(["git","commit","--message","hi"])` →
      `subcommand_id=1`, `flag_count=1`, `--message` slot
      present with value pointing at `"hi"`, `error_code=0`.
    - `parse_argv(["git","push","--force"])` →
      `subcommand_id=2`, `flag_count=1`, `--force` boolean
      present, `error_code=0`.
    - `parse_argv(["git","clone"])` → `rax=19`,
      `error_code=19`, `error_arg_index=1`,
      `subcommand_id=0`.
    - `parse_argv(["git","--version"])` (with StdVocab
      `register_all`) → `rax=13 (ERR_VERSION_EMITTED)`,
      `subcommand_id=0` — the auto-emit fires because
      argv[1] is flag-shaped and dispatch short-circuits.

  Without any `register_subcommands` call: `parse_argv` is
  byte-for-byte pre-ENH-020 for every existing matrix case.

Klog tag: `pdxargv.subcommand`.

Not touched by ENH-020 (out of scope):

  - No nested subcommands. The match-path `flag_spec_reset`
    wipes the sub table pointer so the sub's own parse never
    re-enters the dispatch phase. A `pkg install --dry-run`
    tree where `install` is itself a sub-sub is a follow-on
    ENH; the semver-safe shape is a `SubSpec.sub_table_ptr` /
    `sub_table_count` pair the parser reads between the
    `flag_spec_reset` and the flag_spec_register loop.
  - No wider `SubFlagSpec` variants. A sub wanting a
    separator-required (`--foo=<x>` only) or range-bounded INT
    or enum-STR flag composes it after dispatch or waits for
    the follow-on wider shapes.
  - No first-non-flag scanning. The classifier looks at
    `argv[1]` only; `["git","-C","/path","commit"]` finds
    argv[1] = `-C` (flag-shaped) → no dispatch. Walking past
    a top-level flag prefix needs each prefix flag's arity
    consulted BEFORE dispatch, an ordering split ENH-020 does
    not owe today.
  - No SchemaInvoke-path dispatch. The wire-form invocation
    path has no argv[1] to classify; sub-scoped dispatch on
    that path is a wire-form extension a future ENH would
    spec.
  - No ABI change for existing callers. Every consumer that
    never calls `register_subcommands` sees the parser's
    dispatch phase short-circuit at the null-pointer check;
    behavior on every existing matrix case is byte-for-byte
    pre-ENH-020.

Files touched:

  - `src/parsed_args.pdx` — adds `ERR_UNKNOWN_SUBCOMMAND = 19`
    and `subcommand_id : u64` bss slot; updates
    `parsed_args_reset` to zero the new slot.
  - `src/flag_spec.pdx` — adds `subcommand_table_ptr` /
    `subcommand_table_count` bss slots, the six `SUBSPEC_OFF_*`
    + `SUBSPEC_STRIDE` layout constants, the four
    `SUBFLAGSPEC_OFF_*` + `SUBFLAGSPEC_STRIDE` layout constants,
    and the `register_subcommands` install function; updates
    `flag_spec_reset` to zero both new slots.
  - `src/parser.pdx` — adds the ENH-020 dispatch phase to
    `parse_argv_ex` (five new labels: `parse_argv_sub_scan_head`
    / `parse_argv_sub_strcmp_head` / `parse_argv_sub_match` /
    `parse_argv_sub_reg_head` / `parse_argv_sub_unknown`);
    updates the module-level preamble and the `parse_argv_ex`
    justification. No changes to the `parse_argv` /
    `parse_argv_skipping_zero` wrappers or the main-loop
    labels.
  - `tests/parse_subcommands.pdx` — NEW; six regression
    cases matching the issue fingerprint (module id 10).
  - `tests/smoke_driver.pdx` — dispatches
    `ParseSubcommandsTests::run_case1..6`.
  - `tests/harness.pdx` — module-id table comment gains
    the `10 = parse_subcommands` row.
  - `design/architecture.md` — new §19 covering surface
    delta, byte layouts, dispatch state machine, collect-all
    interaction, StdVocab precedence, fingerprint, and the
    "explicitly does not do" list.
  - `README.md` — appends `ERR_UNKNOWN_SUBCOMMAND` (19) to the
    error-constant paragraph with the ENH-020 additions
    block; adds `register_subcommands` row to the
    `flag_spec.pdx` table; extends the `parse_argv` /
    `parse_argv_ex` row with the ENH-020 dispatch phase
    description.
  - `doc/libpdx-argv.pdxdoc` — appends the
    `ERR_UNKNOWN_SUBCOMMAND (19)` DIAGNOSTICS entry and a new
    Unreleased HISTORY row.

### ENH-019 — STRING flag enum validation via `register_string_enum` (Closes #29)

Pre-ENH-019 an FKIND_STR flag was a raw byte channel: the parser
stored the value pointer verbatim and every consumer wanting to
gate on a fixed vocabulary — "must be one of `auto`, `always`,
`never`" — re-implemented the same three-string strcmp against a
locally-declared table, five to ten lines of near-identical
boilerplate per call site with no shared error code. ENH-019
lifts the check into the library at registration time, mirroring
the ENH-018 shape for INT ranges (§13 of `design/architecture.md`).

Public surface additions:

  - `FlagSpec::register_string_enum(name_ptr, id, allowed_ptr,
    allowed_count) -> ()` — registers `name` at kind = `FKIND_STR`
    (1) with the caller-owned array of NUL-terminated string
    pointers (`*const *const u8`) as the allowed-values gate.
  - `FlagSpec::spec_allowed_ptr : [u64; 32]` and
    `FlagSpec::spec_allowed_count : [u64; 32]` — the per-slot
    storage backing the gate.
  - `FlagSpec::last_lookup_allowed_ptr : u64` and
    `FlagSpec::last_lookup_allowed_count : u64` — companion "out
    parameter" slots that every `lookup()` call publishes, same
    shape as `last_lookup_sep_required` (ENH-010). A miss zeroes
    both.
  - `ParsedArgs::ERR_STRING_ENUM : u64 = 18` — set by the parser
    on a gate rejection.

Parser changes (`src/parser.pdx`):

  - Two inline enum-walk blocks (one at each of the long-flag and
    short-flag store sites) run immediately after the flag_names
    / flag_values / flag_ids / flag_kinds store, before the
    ENH-017 FKIND_INT gate and the ENH-032 / ENH-014 auto-emit
    dispatches. Each block gates on `kind == FKIND_STR (1) AND
    r14 != 0 AND last_lookup_allowed_count > 0`, then walks the
    caller-registered allowed-values array using the same inline
    `xor+mov_b+cmp` strcmp shape `lookup()` itself uses (first
    match wins).
  - `parse_argv_string_enum` — a new recoverable-fail label near
    `parse_argv_bad_int` that sets `rax = 18` and jumps to
    `parse_argv_maybe_collect`. Reuses the ENH-017 recoverable-
    fail router so the gate participates in collect-all mode
    (advance-past-argv-slot recovery) without extra plumbing.
  - The cluster path (`parse_argv_short_clustered`) is BOOL-only
    per ENH-013's admissibility rule, so no enum walk fires
    there.

Defensive-zero hygiene:

  - Every non-`register_string_enum` registration path
    (`register_with_help`, `register_sep`, `register_int`)
    writes `spec_allowed_ptr[slot] = 0` and
    `spec_allowed_count[slot] = 0` at the store site, so a slot
    recycled from a `register_string_enum` batch never inherits
    a stale allowed set. This mirrors the ENH-018 defensive-zero
    pattern for `spec_min` / `spec_max`.

Semantics summary:

  - **Sentinel: `allowed_count == 0` means "gate OFF"**. The
    plain `flag_spec_register(name, FKIND_STR, id)` path writes
    exactly this via the defensive-zero block, so every
    pre-ENH-019 STR registration preserves byte-for-byte
    behaviour. `register_string_enum(..., 0, 0)` is the
    equivalent-but-explicit spelling.
  - **Case-sensitive byte compare**. No ASCII-case normalisation
    anywhere in the walk — `"AUTO"` never matches an `"auto"`
    entry. Consumers wanting case-insensitive vocabularies
    register the equivalence classes explicitly
    (`{"auto\0", "AUTO\0", "Auto\0"}`).
  - **Gate independence from the collect-all bit**. Unlike
    ENH-017's inline FKIND_INT validation, the FKIND_STR enum
    walk fires on BOTH `parse_argv` and `parse_argv_ex(..., 0)`
    because the allowed set is a per-registration property
    opted into at `register_string_enum` time. Under the
    collect-all bit the fail routes through the same
    `parse_argv_maybe_collect` router as every other
    recoverable fail — the parser records ERR_STRING_ENUM and
    advances past the offending argv slot instead of returning.
  - **Store not rolled back**. On rejection the parser-observed
    (name, offending-value, id, STR) triple stays in
    `flag_names[k]` / `flag_values[k]` / `flag_ids[k]` /
    `flag_kinds[k]` — same discipline as `ERR_BAD_INT`.
    Consumers walking `ParsedArgs` after a parse that returned
    (or collected) `ERR_STRING_ENUM` treat the offending
    `FKIND_STR` slot as diagnostic-only.
  - **First-error wins**. On a plain `parse_argv` the router
    falls through to `parse_argv_epilogue` after the ring seed
    (byte-for-byte pre-ENH-017 return-on-first-error semantics);
    under collect-all the epilogue returns
    `error_ring_codes[0]` per the ENH-017 first-error preservation
    contract.

Fingerprint (issue #29) — the parse_typed_values_tests.pdx cases
30-34 are the regression fixtures:

  With `register_string_enum("--color", ID_COLOR, &["auto\0",
  "always\0", "never\0"], 3)`:

    - `parse_argv(["--color", "auto"])`   → `ERR_OK`
    - `parse_argv(["--color", "always"])` → `ERR_OK`
    - `parse_argv(["--color", "never"])`  → `ERR_OK`
    - `parse_argv(["--color", "mauve"])`  → `ERR_STRING_ENUM (18)`;
      `error_code = 18`; `flag_count = 1` (store preserved)
    - `parse_argv(["--color", "AUTO"])`   → `ERR_STRING_ENUM (18)`
      (case-sensitive rejection)

  With `register_string_enum("--color", ID_COLOR, 0, 0)`:

    - `parse_argv(["--color", "mauve"])`  → `ERR_OK` (gate OFF)

Klog tag: `pdxargv.string-enum`.

Not touched by ENH-019 (out of scope):

  - No `register_string_enum_sep()` variant. A tool wanting a
    bounded STR flag whose spelling ALSO mandates a separator
    (`--color=<mode>` only) has to compose that via
    `register_sep()` followed by a manual post-hoc
    `spec_allowed_ptr` / `spec_allowed_count` write — a
    follow-on ENH parallel to ENH-018's future
    `register_int_sep()`.
  - No FKIND_ENUM interaction. `FKIND_ENUM (5)` remains the
    StdVocab-owned kind for `--color`'s I3 spelling; the
    ENH-019 gate is orthogonal, addressing the FKIND_STR flow
    specifically.
  - No SchemaInvoke-path gate. The schema-record's typed
    values are decoded upstream; adding a gate there would need
    a shared allowed-list wire schema.
  - No ABI change for existing callers. Every non-STR-enum
    registration path preserves its pre-ENH-019 signature; the
    defensive-zero additions are internal store-block details.

### ENH-017 — Collect-all-errors mode via `ARGV_COLLECT_ALL_ERRORS` (Closes #27)

Pre-ENH-017 `Parser::parse_argv` returned on the first parse
failure — a config-file linter or a shell-completion analyser that
wanted every diagnostic in one pass had to re-invoke the parser
per fixup or roll its own argv walk (losing the library's typed-
flag / clustered-short / strict-mode discipline). ENH-017 lands
an opt-in accumulator that keeps the parser walking after each
recoverable failure, capping at `MAX_COLLECTED_ERRORS = 16`
records in a bss ring the consumer reads via
`error_count()` / `error_at(i)`.

Public surface additions (all in `ParsedArgs`):

  - `ARGV_COLLECT_ALL_ERRORS : u64 = 1` — bit 0 of
    `parse_argv_ex`'s third argument; opts into multi-error
    accumulation AND inline `FKIND_INT` value validation.
  - `MAX_COLLECTED_ERRORS : u64 = 16` — ring capacity.
  - `ERR_BAD_INT : u64 = 17` — recorded when an inline
    `Typed::parse_int_u64` call on a stored INT flag's value
    returns `ok == 0` (fires ONLY under collect-all mode).
  - `error_ring_codes : [u64; 16]`, `error_ring_indices : [u64; 16]`,
    `error_ring_count : u64` — parallel-array ring (256 B .bss)
    plus live-entry counter.
  - `error_count() -> u64` (leaf) — returns `error_ring_count`.
  - `error_at(idx) -> u64` (leaf, multi-return `rax:rdx`) — reads
    `(error_ring_codes[idx], error_ring_indices[idx])`; OOB
    returns `(0, 0)`.

Parser surface additions:

  - `parse_argv_ex(argv, argc, parse_flags) -> u64` — the ENH-017
    primary. `parse_flags = 0` reproduces the pre-ENH-017 shape
    byte-for-byte; bit 0 (`ARGV_COLLECT_ALL_ERRORS`) turns on the
    accumulator + inline INT validation.
  - `parse_argv(argv, argc) -> u64` — now a thin wrapper over
    `parse_argv_ex(argv, argc, 0)`. Signature preserved: every
    existing consumer (pkg, ls, cp, mkdir, mv, rm, mkfs.pdxfs,
    mount.pdxfs, umount.pdxfs, every satellite/test) links
    unchanged and sees zero behavior change.

Semantics summary:

  - **First-error preservation.** The FIRST error observed
    always writes into `ParsedArgs::error_code` / `error_arg_index`
    AND lands in `error_ring[0]`, regardless of the collect bit.
    A consumer that never reads the ring still sees the first
    failure via the pre-existing scalar slots.
  - **Return-value discipline.** Every exit path with ring
    content returns `error_ring_codes[0]` — the first-error
    code. `parse_argv_epilogue` reads the ring and updates rax
    before ret, so consumers see the "first error wins" semantic
    on every exit (success, hard-stop, collect-mode end-of-argv).
  - **Recoverable-fail routing.** `parse_argv_unknown_flag`,
    `parse_argv_missing_value`, `parse_argv_unknown_arg_form`,
    `parse_argv_long_missing_name`,
    `parse_argv_cluster_with_arity`, and (new)
    `parse_argv_bad_int` all jump to `parse_argv_maybe_collect`.
    The router records + tests the bit; on set, advances to the
    next argv slot; on unset, falls through to
    `parse_argv_epilogue` (return).
  - **Hard-stop fails.** `parse_argv_flag_overflow` and
    `parse_argv_pos_overflow` still route directly to
    `parse_argv_fail` (storage-exhausted; continuing would trip
    the same gate on every subsequent slot). The direct-fail
    path also populates `error_ring[0]` if the ring is empty and
    appends the hard-stop error otherwise.
  - **Auto-emit success signals unchanged.** `ERR_VERSION_EMITTED`
    (ENH-032) and `ERR_HELP_EMITTED` (ENH-014) still stop the
    parse under both modes; they are intentional early exits.
  - **Ring overflow is silent.** Beyond `MAX_COLLECTED_ERRORS`
    the ring drops subsequent records but the parse still
    advances past each — parse-side state stays coherent.

Ring layout (per-slot fields, chosen over embedding the full
`PdxArgvParseErrorRecord@0.1` layout):

  - **Two parallel `[u64; 16]` arrays**: `error_ring_codes` and
    `error_ring_indices`. Each slot carries `(err_code,
    argv_index)` in 16 B total. 16 slots × 16 B = 256 B .bss.
  - Deliberately NOT `PdxArgvParseErrorRecord@0.1` records
    (32 B header + variable-length token bytes). The full-record
    shape is what `SchemaEmit::emit_parse_error` writes into a
    caller-supplied buffer for wire-form serialisation; the
    parse-time ring keeps only the two scalar fields the parser
    already has in hand and defers token retrieval to the
    caller (`argv[error_at(i).argv_index]` reads the offending
    token verbatim). This keeps the ring inside 256 B of .bss,
    stays inside the paideia-as `mov [reg + rcx*8], reg`
    addressing mode (no scaled `(rcx*16)` or two-store
    sequences), and avoids a variable-length-record allocator
    inside the parser.

Inline `FKIND_INT` value validation (opt-in with the collect bit):

  - After every long-flag or short-flag store whose `kind ==
    FKIND_INT (2)` and `value != null`, the parser calls
    `Typed::parse_int_u64(value)`. On `ok == 0` it records
    `ERR_BAD_INT (17)` with `argv_index = r13` (the value slot,
    since the parser has already advanced past the flag onto its
    value) and jumps to `parse_argv_maybe_collect` for the
    advance-past-argv-slot recovery.
  - The store is NOT rolled back: `flag_names[k]` / `flag_values[k]`
    / `flag_ids[k]` / `flag_kinds[k]` reflect the (name, raw-
    string-value, id, INT) triple the parser observed. Consumers
    walking `ParsedArgs` post-parse in collect-all mode treat any
    FKIND_INT slot whose value fails `parse_int_u64` as
    diagnostic-only.
  - The validation is opt-in with the collect bit — plain
    `parse_argv(argv, argc)` (bit unset) never calls the decoder
    at parse time; the pre-ENH-017 contract that INT decoding
    happens at the consumer's dispatch site is preserved byte-
    for-byte. This also avoids a behavior change for consumers
    that deliberately accept non-numeric INT values (e.g.
    `--jobs auto` where "auto" is a tool-specific sentinel).

Fingerprint (issue #27):

Under `ARGV_COLLECT_ALL_ERRORS` with argv
`["tool", "--zog", "--bad-int", "notanumber", "--", "pos"]`
(`parse_argv_ex`, argc = 6), where `--zog` is unregistered under
`FlagSpec::set_strict(1)` and `--bad-int` is registered as
`FKIND_INT` with id 100:

  - Return value = `ERR_UNKNOWN_FLAG` (12) — first-error code
    via `parse_argv_epilogue`'s ring[0] read.
  - `error_code == 12`, `error_arg_index == 1` — first-error
    scalar slots seeded by the very first
    `parse_argv_maybe_collect`.
  - `error_count() == 2`.
  - `error_at(0) == (12, 1)` — `--zog` unknown-flag record.
  - `error_at(1) == (17, 3)` — `notanumber` bad-int record;
    argv_index is the value slot the parser was on when
    `parse_int_u64` returned ok = 0.
  - `pos_count == 2` — `argv[0]="tool"` + `argv[5]="pos"`.
  - `ddash_seen == 1`, `ddash_arg_index == 4`.

Without the bit (plain `parse_argv(argv, 6)`), the same argv
returns after `--zog` with `error_count() == 1`, `error_code == 12`,
`pos_count == 1` — byte-for-byte identical to the pre-ENH-017
`parse_argv` return-on-first-error contract. The ring's single-
slot seed is the only observable delta and does not affect any
consumer that reads only the scalar slots.

Implementation shape:

  - `parse_argv_ex` spills its third argument (`parse_flags`)
    into the alignment-pad slot at `[rsp + 0]` (the 8-byte
    padding the 6-push prologue already reserves for nested-call
    stack alignment). The slot was previously unused; ENH-017
    repurposes it without changing the prologue shape or the
    `rsp%16 = 0` invariant for nested calls. Every recoverable-
    fail gate reloads via `mov rcx, [rsp + 0]` and tests bit 0.
  - `parse_argv` (the thin wrapper) uses a 1-push prologue
    (`push rbx` for alignment, `rbx` unused), stages
    `rdx = 0`, and calls `parse_argv_ex` — same shape
    `parse_argv_skipping_zero` uses for its own wrap.
  - `parse_argv_maybe_collect`, `parse_argv_bad_int`, and
    `parse_argv_epilogue` are new labels. `parse_argv_fail`
    grows a first-error preservation check (skip the scalar-
    slot writes if the ring already has content) so a hard-fail
    after prior recoverable errors does not clobber the first-
    error slots. `parse_argv_done_ok` grows the same guard so a
    collect-mode success walk with prior errors returns the
    first-error code, not `ERR_OK`.

Files touched:

  - `src/parsed_args.pdx` — adds `ARGV_COLLECT_ALL_ERRORS`,
    `MAX_COLLECTED_ERRORS`, `ERR_BAD_INT`, the ring bss trio
    (`error_ring_codes`, `error_ring_indices`, `error_ring_count`),
    `error_count`, `error_at`. Updates `parsed_args_reset` to
    zero the ring counter.
  - `src/parser.pdx` — renames the primary implementation to
    `parse_argv_ex(u64, u64, u64)`; adds `parse_flags` spill at
    `[rsp + 0]`; adds INT-validate gates to both long-flag and
    short-flag store paths; adds `parse_argv_maybe_collect`,
    `parse_argv_bad_int`, `parse_argv_epilogue`, and a thin
    `parse_argv` wrapper. Re-routes every recoverable-fail
    label to `parse_argv_maybe_collect` (keeps the two overflow
    labels routing to `parse_argv_fail` directly).
  - `tests/parse_grammar_tests.pdx` — adds case 35 (the
    fingerprint above), which exercises both the bit-set path
    (collect-all + INT validation) AND the pre-ENH-017 backward-
    compat shape (`parse_argv` — same argv returns after `--zog`
    with `error_count() == 1`).
  - `tests/smoke_driver.pdx` — wires `run_case35` into the
    driver after `run_case34`.
  - `design/architecture.md` — adds §17 (Collect-all-errors
    mode) covering entry-point surface, ring semantics, overflow
    behavior, inline FKIND_INT validation, recoverable-fail
    routing, fingerprint, and the "explicitly does not do" list.
  - `README.md` — appends `ERR_BAD_INT` (17) to the error-
    constant paragraph, adds the ENH-017 additions block, wires
    `parse_argv_ex` into the parser API table, annotates
    `parse_argv` as a thin wrapper, adds `error_count` and
    `error_at` rows to the ParsedArgs API table, extends the
    `parsed_args_reset` row.
  - `doc/libpdx-argv.pdxdoc` — appends a collect-all invocation
    example to SYNOPSIS, adds `ERR_BAD_INT (17)` to DIAGNOSTICS,
    adds an Unreleased HISTORY entry.

Klog tag: `pdxargv.collect-errors`.

### ENH-013 — Clustered short flags for BOOL/COUNTED registrations (Closes #23)

M1-002 (#2) locked a one-per-hyphen short-flag grammar: any cluster
`-abc` was rejected wholesale with `ERR_CLUSTERED_SHORT` (4). ENH-013
narrows the reject to the hazard that motivated D3 — a value-consuming
short flag inside a cluster (`-nX` where `-n` is INT) that would
swallow one of its neighbours or its value — and admits the mainstream
BOOL/COUNTED cluster idiom (`-vv` for verbosity, `-abc` for three
switches).

`Parser::parse_argv` now handles the `-abc` classifier arm two-pass.
Pass 1 walks the cluster once, calling `FlagSpec::lookup` on each
letter (via a 2-byte `cluster_probe` scratch = letter + NUL), and
fails fast:

  - `FKIND_UNKNOWN` + `strict_mode != 0` → `ERR_UNKNOWN_FLAG` (12)
    per ENH-004, unchanged from the single-letter short path.
  - Any kind other than `FKIND_BOOL` (0) or (permissive)
    `FKIND_UNKNOWN` → `ERR_CLUSTER_WITH_ARITY` (16), the new code.
    No letter is dispatched — `flag_count` is unchanged from
    cluster entry (no partial storage).

Pass 2 walks the cluster again. For each letter it writes
`letter, NUL` into `cluster_scratch_buf[flag_count * 2 ..
flag_count * 2 + 2)` (64-byte parser-owned buffer = 2 bytes × MAX_FLAGS)
and stores `(name_ptr, 0, id, kind)` into
`flag_names/flag_values/flag_ids/flag_kinds[flag_count]` under the
existing `MAX_FLAGS` overflow gate. The second lookup per letter is
deliberate — a straight-line pair of walks reads better than a
triple-buffer between passes and stays inside the parser's existing
`FlagSpec::lookup` cost envelope (2N calls per cluster of length N,
capped by 2 × 32 × 32 = 2048 comparisons per parse).

Cluster stores deliberately skip the ENH-032 (`--version`) and
ENH-014 (`--help`) auto-emit dispatches — a tool that registers
`-h`/`-v` shorts with the standard ids gets the auto-emit only when
the letter is typed without clustering, which matches the
mainstream `-vvv` idiom (see §16.5 in `design/architecture.md`).

Fingerprints (issue #23):

  - `-v` alone works (baseline; single-letter short path
    unchanged) — covered by `tests/parse_grammar.pdx` case 7.
  - `-vv` on COUNTED flag `v` (FKIND_BOOL registered) increments
    `count_flag_by_id(id) → 2` — new `case 31`.
  - `-abc` where a/b/c all FKIND_BOOL → `flag_count == 3`; each
    id resolvable via `find_flag_by_id` — new `case 32`.
  - `-abc` where `b` is FKIND_STR → `ERR_CLUSTER_WITH_ARITY = 16`,
    `flag_count == 0`, `error_arg_index == 0` — new `case 33`.
  - `-abc` where `a` unregistered under `set_strict(1)` →
    `ERR_UNKNOWN_FLAG = 12`, `flag_count == 0` — new `case 34`.

Also updates `tests/parse_grammar.pdx` case 6 in place: `-la` under
permissive mode with no registrations now returns `ERR_OK` with
`flag_count = 2` (both letters expanded, ids 0, kinds
`FKIND_UNKNOWN`) — the case documented the M1-002 → ENH-013
semantics change as a regression witness. Pre-ENH-013 this fixture
returned `ERR_CLUSTERED_SHORT (4)`. Consumers pattern-matching on
that error code need updating: it is now unreachable from the
parser (the constant is retained in `parsed_args.pdx` for wire-form
back-compat).

Files touched:

  - `src/parsed_args.pdx` — adds `ERR_CLUSTER_WITH_ARITY = 16`
    with the full ENH-013 docstring; annotates `ERR_CLUSTERED_SHORT`
    as unreachable-post-ENH-013 (constant retained for wire-form
    back-compat).
  - `src/parser.pdx` — adds two `pub let mut` scratch buffers
    (`cluster_probe : [u64; 1]` and `cluster_scratch_buf :
    [u64; 8]`); replaces the `parse_argv_short_clustered` label's
    unconditional-reject stub with the two-pass validation +
    dispatch code (labels `parse_argv_cluster_val_*` and
    `parse_argv_cluster_disp_*`) plus a new
    `parse_argv_cluster_with_arity` fail label. Module preamble
    gets a new ENH-013 section explaining the two-pass shape,
    scratch sizing (64 bytes = 2 × MAX_FLAGS), and the auto-emit
    skip; `parse_argv`'s own docstring appends the same summary.
  - `tests/parse_grammar_tests.pdx` — updates case 6 in place to
    the new expanded semantics; adds cases 31 / 32 / 33 / 34
    matching the four issue fingerprints. Total ParseGrammarTests
    case count is now 34.
  - `tests/smoke_driver.pdx` — wires `run_case31` … `run_case34`
    into the driver after `run_case30`.
  - `design/architecture.md` — updates § 5 heading to point at
    § 16 for the relaxation; adds § 16 (five subsections covering
    admissibility, two-pass shape, scratch sizing,
    dispatched-flag observables, and the "explicitly does not
    do" list).
  - `README.md` — appends `ERR_CLUSTER_WITH_ARITY` (16) to the
    error-constant paragraph; rewrites the grammar summary to
    describe the BOOL/COUNTED cluster expansion.
  - `doc/libpdx-argv.pdxdoc` — expands FLAG GRAMMAR to include
    the `-abc` clustered form; rewrites BREAKS WITH POSIX to
    document the ENH-013 admissibility rule; adds the
    `ERR_CLUSTER_WITH_ARITY (16)` row and the "LEGACY" note on
    `ERR_CLUSTERED_SHORT (4)` in DIAGNOSTICS.

Klog tag: `pdxargv.short-cluster`.

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
