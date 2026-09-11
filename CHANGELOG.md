# libpdx-argv — CHANGELOG

All notable changes to `libpdx-argv` are recorded here. The format is
loosely modelled on Keep-a-Changelog, adapted to the PaideiaOS milestone
rubric in `design/tooling/r49-r50-plan.md` §5.

## Unreleased

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
