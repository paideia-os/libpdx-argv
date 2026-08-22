# libpdx-argv.M4-001 — implementation notes

**Issue:** #9 — parse-correctness matrix + clustered-short-flag
rejection tests + typed-arg-parse-error diagnostics + `--help` render
round-trip via doc.

**Upstream doc:** `design/tooling/r49-r50-plan.md` §5.12 (paideia-os).

## What landed

- `tests/harness.pdx` — new `TestHarness` module. Public surface:
  - `TestHarness::pass_count : u64` — .bss singleton, incremented
    by every green case.
  - `TestHarness::fail_count : u64` — .bss singleton, incremented by
    every red case.
  - `TestHarness::last_fail_tag : u64` — encoded as
    `(module_id << 32) | case_number` so an interactive debugger can
    see WHICH case failed without instrumenting every assertion.
  - `TestHarness::reset_tally()` — zero all three counters (called
    once by the smoke driver at `_start`).
  - `TestHarness::record_pass()` / `TestHarness::record_fail(tag)` —
    per-case tally increments.
  - `TestHarness::full_reset()` — zero `ParsedArgs` + `FlagSpec` +
    `SchemaEmit` singleton state so a test can begin from a known-
    clean fixture. Non-leaf; 1-push alignment for the three nested
    resets.

- `tests/parse_grammar.pdx` — `ParseGrammarTests`, 12 cases:
  - Case 1  — `--help` (boolean long).
  - Case 2  — `--color=auto` (`=` separator, ENUM).
  - Case 3  — `--no-cap:KIND_TTY` (`:` separator, STR — M2-003 universal).
  - Case 4  — `--json foo` (BOOL does NOT consume next arg; cat-M1 fix).
  - Case 5  — bare `--` sentinel + subsequent-args-as-positional.
  - Case 6  — clustered `-la` REJECTED with `ERR_CLUSTERED_SHORT`.
  - Case 7  — single-letter `-n` accepted.
  - Case 8  — `--=foo` → `ERR_LONG_MISSING_NAME`.
  - Case 9  — `--:foo` → `ERR_LONG_MISSING_NAME`.
  - Case 10 — bare `-` treated as positional (stdin convention).
  - Case 11 — `--pdx-schema` sets `emit_schema=1`.
  - Case 12 — mixed `--verbose foo --quiet bar` interleave.

- `tests/parse_typed_values.pdx` — `ParseTypedValuesTests`, 17 cases
  covering the `Typed::parse_*` leaf parsers:
  - parse_int_u64: 0, 42, empty, non-digit trailing.
  - parse_size: 0, 1k/1K, 2m, 3g (0xC0000000), 1kb (rejected), suffix-only (rejected).
  - parse_timespan: bare 60, 1s, 2m (=120), 3h (=10800), 7d (=604800),
    'w' unsupported at M2.

- `tests/parse_typed_args.pdx` — `ParseTypedArgsTests`, 5 cases
  covering M2-001 FlagSpec-driven typed-arg consumption:
  - Long typed lookahead (`--older-than 7d`).
  - Long typed missing value → `ERR_MISSING_VALUE`.
  - Long typed inline (`--older-than=7d`).
  - Short typed lookahead (`-n 5`).
  - Short typed missing value → `ERR_MISSING_VALUE`.

- `tests/parse_std_vocab.pdx` — `ParseStdVocabTests`, 2 sweeps:
  - `run_all_9`: full 9-flag argv, verify every id 1..9 discoverable.
  - `run_ids_unique`: FlagSpec::lookup on each of the 9 std names
    returns the expected id (no accidental collision).

- `tests/parse_schema_record.pdx` — `ParseSchemaRecordTests`, 6 cases
  covering the M3-001 wire form:
  - Happy path (1 flag + 1 pos).
  - Bad magic → `ERR_SCHEMA_BAD_MAGIC`.
  - Bad version (99) → `ERR_SCHEMA_UNSUPPORTED_VERSION`.
  - Short header → `ERR_SCHEMA_BAD_LAYOUT`.
  - `flag_count > MAX_FLAGS` → `ERR_SCHEMA_BAD_LAYOUT`.
  - Body-fits gate (supplied len < header + arrays) →
    `ERR_SCHEMA_BAD_LAYOUT`.

- `tests/help_backend.pdx` — `HelpBackendTests`, 3 cases:
  - `DOC_TOOL_NAME` bytes are `{'d','o','c',0}`.
  - `fill_doc_argv` round-trip: `argv[0] = &DOC_TOOL_NAME`,
    `argv[1] = tool_name_ptr`.
  - `argv[0]` stable across two independent calls.

- `tests/schema_emit.pdx` — `SchemaEmitTests`, 5 cases:
  - Empty-after-reset (count=0, get_name(0)=0).
  - Register two, then get_count/get_name.
  - `SCHEMA_MAX=8` clamp (9th registration silently drops).
  - `get_name(idx >= count)` returns 0.
  - `reset` re-zeros count.

- `tests/smoke_driver.pdx` — `SmokeDriver::_start` calls every
  `run_case*` in module order, then packs `(pass_count << 16) |
  fail_count` and hands off to a linker-provided `SysExit::exit`.
  Exit-code convention: low-16 == 0 means every case passed.

- `tests/README.md` — coverage matrix + how-to-run notes. Rewritten
  from the M1 stub which said "empty at M1 by design".

- `STATUS.md` — M3 → M4 transition; rollup entry for M4-001.

- `design/architecture.md` — §11 M4 additions: test-harness shape,
  module-id table, wire-form fixture rationale for
  parse_schema_record.

## Design decisions

- **Singleton tally + per-test full_reset.** The .bss singleton
  pattern used throughout libpdx-argv (ParsedArgs, FlagSpec,
  SchemaEmit) makes a caller-owned harness impossible without a
  parallel refactor of the library itself. Instead, TestHarness
  mirrors the pattern: pass/fail counters are singletons, and
  every test module's `run_case*` calls `TestHarness::full_reset`
  at head to bring ParsedArgs/FlagSpec/SchemaEmit to a known state.
  The caller-owned `ParsedArgs*` variant referenced in the M1
  architecture doc is a post-M5 concern.

- **Fail-tag encoding `(module_id << 32) | case_number`.** A single
  qword slot in `last_fail_tag` records where the most recent
  failure occurred. Overwrite (not append) semantics keep the
  harness free of a growing per-case failure log — an interactive
  debugger re-runs the driver after gating out prior-passing cases.
  Module IDs 1–9 are reserved in `tests/README.md` §3 and match the
  file names.

- **Fail-tag uses imm64 form.** Every fail tag is
  `0x{module}00000000{case}` (e.g. `0x100000006` = module 1, case 6).
  Values > 0x7FFFFFFF force the paideia-as encoder onto the
  `mov reg, imm64` path (R48 imm64 sweep). This is a deliberate
  stress on the encoder — a smoke that never exercises imm64
  wouldn't catch an imm64-regression in the tooling chain.

- **Wire-form fixture inline byte layout.** `parse_schema_record.pdx`
  hand-codes 65-byte / 32-byte / 16-byte `.rodata` records with
  little-endian qword fields and offset pointers. This is
  deliberately fragile — any change to the wire form in `SchemaInvoke`
  (§10.1 of `design/architecture.md`) requires updating the offsets
  and bytes here in lock-step. The test IS the layout pin: a
  schema-fingerprint negotiation for `PdxArgvRecord@0.1` can trust
  that the byte-for-byte layout matches this fixture.

- **`3g` size check uses reg-reg compare.** `3 << 30 = 0xC0000000`
  exceeds `imm32` (0x7FFFFFFF); the case9 fixture loads the
  expected value via `mov r15, 0xC0000000` and compares against r14
  register-to-register, avoiding the immediate-size violation.

- **`SysExit::exit` is a link-time symbol.** libpdx-argv is a pure
  userspace library with `caps.decl: requires: (none)`. The smoke
  driver needs a way to hand its packed tally back to the process
  boundary — that's the SysExit dependency. The driver expects a
  smoke-binary wiring layer (analogous to `src/user/syscall_shim.pdx`
  in paideia-os) to provide the real definition. If the smoke is
  ever built in isolation with no SysExit shim, the linker will
  fail loudly — which is the desired behaviour.

- **No `--help` output byte-diff at M4.** The plan's M4 line calls for
  "`--help` render round-trip via doc". libpdx-argv's obligation
  here is the *argv-synthesis contract* — `fill_doc_argv` produces
  the correct two pointers — which is exactly what
  `help_backend.pdx` verifies. Byte-diff of the rendered `.pdxdoc`
  output is doc's obligation, tested by doc's own M4 (dependency
  edge: `libpdx-argv.M3` unblocks `doc.M2` per `§5.5 doc`).

- **Test-harness module id 4 reserved for parse_positional_ext.**
  The M4-001 scope covers the positional-argument list surface via
  parse_grammar cases 5, 10, 12 (bare `--`, bare `-`, mixed
  interleave). A dedicated parse_positional module remains reserved
  for M4+ additions (e.g. pos_count overflow at MAX_POS boundary,
  which is a low-value stress case at bootstrap-scope where every
  observed CLI stays well under 32 positionals).

## paideia-as conformance

- All test modules are `PascalCase basename` (`TestHarness`,
  `ParseGrammarTests`, `ParseTypedValuesTests`, `ParseTypedArgsTests`,
  `ParseStdVocabTests`, `ParseSchemaRecordTests`, `HelpBackendTests`,
  `SchemaEmitTests`, `SmokeDriver`).
- No `test` mnemonic anywhere; every zero-check via `cmp reg, 0`.
- Every `cmp reg, imm` uses immediate ≤ 0x7FFFFFFF (max: 0xC0000000
  in parse_typed_values case9 uses reg-reg compare after loading via
  `mov r15, 0xC0000000`).
- `r11` is scratch (used only for `lea r11, [rip + xxx]` cross-module
  .bss / .rodata bases; never live across a call).
- Byte loads (rare in tests — used by `run_case4` positional-content
  check and `run_case1` of help_backend for DOC_TOOL_NAME identity)
  use `xor rax, rax; mov_b rax, [ptr]` per the #1248 mitigation.
- Non-leaf `run_case*` fns use a 1-push (rbx unused) prologue for
  `rsp%16 = 0` at each nested call site; cases that need to preserve
  a comparison value across `record_pass`/`record_fail` (case9 in
  parse_typed_values, case2 in help_backend, several in
  parse_typed_args) push both `rbx` and `r15` (2-push) or add a
  `sub rsp, 8` for the 3rd slot to keep alignment.

## Cross-module linkage

Tests call:

- `ParsedArgs::reset`, `ParsedArgs::find_flag_by_id` — the singleton
  reset + id-lookup for assertions.
- `FlagSpec::reset`, `FlagSpec::register`, `FlagSpec::lookup` — set
  up per-test flag vocab; verify `ids_unique` in std_vocab tests.
- `StdVocab::register_all` — bulk-register the 9 std flags for the
  vocabulary sweep and every case that names --help / --color etc.
- `SchemaEmit::reset`, `SchemaEmit::register`, `SchemaEmit::get_count`,
  `SchemaEmit::get_name` — schema_emit tests only.
- `Parser::parse_argv` — the main entry under test.
- `SchemaInvoke::parse_from_schema_record` — the M3-001 alt path
  under test.
- `HelpBackend::fill_doc_argv`, `HelpBackend::DOC_TOOL_NAME` — the
  M3-002 argv-synthesis surface under test.
- `Typed::parse_int_u64`, `Typed::parse_size`, `Typed::parse_timespan`
  — leaf-parser round-trip.
- `SysExit::exit` — link-time; smoke-binary wiring provides.
- `TestHarness::full_reset`, `TestHarness::record_pass`,
  `TestHarness::record_fail`, `TestHarness::reset_tally` — the
  harness itself.

Also reads `ParsedArgs`'s .bss symbols directly (`flag_count`,
`flag_values`, `flag_ids`, `pos_count`, `pos_ptrs`, `error_code`,
`error_arg_index`, `emit_schema`, `ddash_seen`, `ddash_arg_index`)
for post-parse assertions.

## What did not land (queued for M4+ / M5)

- **Test-runner integration.** The smoke driver produces a packed exit
  code; a shell wrapper (analogous to `tools/verify-user-tokenizer.sh`
  in paideia-os) that runs the ELF under QEMU + interprets the exit
  code lands with `pkg.M4` per the M4→M5 chain (`libpdx-argv.M5-001`
  depends on `pkg.M4`).
- **Property-based / fuzz driver.** M5+ — needs the pkg CLI wired
  first so the harness can install/run smoke ELFs.
- **`--help` output byte-diff against a golden .pdxdoc render.**
  Needs `doc.M2` runnable. libpdx-argv's obligation stops at the
  argv-synthesis contract (case2/case3 of `help_backend.pdx`).
- **Concurrent multi-parse.** M2/M3 ParsedArgs is singleton-scoped;
  the caller-owned `ParsedArgs*` variant is a post-M5 concern per
  `design/architecture.md` §3.
- **MAX_POS / MAX_FLAGS overflow tests.** The 32-slot cap is deeply
  overprovisioned for every observed P0 tool (max 12 flags + 4 pos in
  `pkg install`). A dedicated overflow-boundary test is a M4+ stretch
  and would need larger argv fixtures than the M4-001 scope justifies.
- **positional-list-ext (module id 4) and mixed-ext (module id 9)** —
  reserved slots in the fail-tag scheme so future test additions
  don't reshuffle the module-id table.
