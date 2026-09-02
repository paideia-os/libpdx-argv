# libpdx-argv — status

**Wave:** R49 shared library
**Current milestone:** M5 (dual-signed release + `.pdxdoc` + mirror
push) — CLOSED. Repo is at v1.1.0 (post-1.0 tranche closed
2026-09-02; see `CHANGELOG.md`). Every milestone issue (#1..#10) is
closed and the tracked post-1.0 issues (#32, #33, #39, #40 — plus
the fixed #34 and #36) have all landed. See `CHANGELOG.md` for the
per-version entries and `design/tooling/r49-r50-plan.md` §5.12 for
the wave-level rubric.

Signature state at 1.1.0: `manifest.pdxsig` is payload-frozen; both
signature slots carry `PENDING:` sentinels and every per-source
sha256 line is `DEFERRED-COMPUTED-AT-RELEASE-RUNNER` (ENH-030
touched every source file in `src/`). Populated in place by
`paideia-as release --sign` (author slot) once v0.33-crypto-kdf is
reachable on the release-runner host, and by the pkgs.paideia-os
mirror runner (paideia_root slot) at admission time — see
paideia-os meta issue `T-INFRA-001`.

## Milestone rollup

| ID              | Title                                                              | State  |
|-----------------|--------------------------------------------------------------------|--------|
| M1-001 (#1)     | scaffold + ParsedArgs struct + long-flag grammar                   | LANDED |
| M1-002 (#2)     | short-flag grammar one-per-hyphen (clustered -> reject)            | LANDED |
| M2-001 (#3)     | typed flag arguments (--older-than 7d, --size > 1MB)               | LANDED |
| M2-002 (#4)     | 9-flag standard vocabulary from I3                                 | LANDED |
| M2-003 (#5)     | positional-argument list handling (`--` sentinel, `:` separator)   | LANDED |
| M3-001 (#6)     | alternate invocation: typed schema record -> ParsedArgs            | LANDED |
| M3-002 (#7)     | --help back-end integration with doc <tool>                        | LANDED |
| M3-003 (#8)     | --schema prints tool's declared output schemas                     | LANDED |
| M4-001 (#9)     | parse-correctness matrix + clustered-short + typed diag + --help round-trip | LANDED |
| M5-001 (#10)    | dual-signed release + .pdxdoc + mirror push (v1.0.0)                     | LANDED |

See `design/tooling/r49-r50-plan.md` §5.12 in paideia-os for the full
milestone breakdown (M1-M5) and cross-repo dependencies.

## Local layout

- `design/architecture.md` — internal spec (M1 record shape + state
  machine + M2 additions: FlagSpec, StdVocab, Typed, positional list
  + M3 additions: SchemaInvoke, HelpBackend, SchemaEmit).
- `src/parsed_args.pdx` — `ParsedArgs` module (error codes + slot
  storage + `find_flag_by_id` helper).
- `src/parser.pdx` — `Parser` module (`parse_argv` entry point;
  M2 non-leaf, calls FlagSpec::lookup once per flag).
- `src/flag_spec.pdx` — `FlagSpec` module (declarative registration
  table; M2-001).
- `src/std_vocab.pdx` — `StdVocab` module (I3 9-flag vocabulary +
  `register_all` helper; M2-002).
- `src/typed.pdx` — `Typed` module (`parse_int_u64`, `parse_size`,
  `parse_timespan`; M2-001).
- `src/schema_invoke.pdx` — `SchemaInvoke` module (alt invocation:
  typed record -> ParsedArgs; M3-001).
- `src/help_backend.pdx` — `HelpBackend` module (`--help` -> doc
  argv synthesis; M3-002).
- `src/schema_emit.pdx` — `SchemaEmit` module (`--schema` declared
  schema-name table; M3-003).
- `caps.decl` — libpdx-argv requires no caps of its own; declares the
  `PdxArgvRecord@0.1` wire schema consumed by SchemaInvoke.
- `tests/` — M4-001 parse-correctness matrix + smoke driver
  (harness + 8 fixture modules + smoke_driver + README). See
  `tests/README.md` for the coverage matrix.
- `.plans/` — per-milestone implementation notes.
- `VERSION` — semver (`1.1.0`).
- `CHANGELOG.md` — release history with the 1.0.0 and 1.1.0 rollups.
- `deps.list` — library dependencies (none; toolchain floor only).
- `manifest.pdxsig` — dual-signed release manifest per §6.3
  (both signature slots PENDING until runner passes complete).
- `doc/libpdx-argv.pdxdoc` — the `doc libpdx-argv` file per I7.
- `pkgs/mirror.entry` — pkgs.paideia-os admission entry
  (consumed once T-INFRA-001 lands in paideia-os).

## Consumer wiring (M3)

Every tool that uses libpdx-argv at M3 follows this init sequence.
Only the argv-vs-record branch (call out below) differs from the M2
shape; downstream dispatch is identical.

```
_start:
  flag_spec_reset()                                // ENH-030 v1.1.0
  register_all()                                   // StdVocab, IDs 1..9
  flag_spec_register(tool_name_a, kind_a, 100)     // tool-specific
  flag_spec_register(tool_name_b, kind_b, 101)
  ...
  schema_emit_reset()                              // ENH-030 v1.1.0
  schema_emit_register(&SCHEMA_NAME_A)             // declared output schemas
  schema_emit_register(&SCHEMA_NAME_B)             // (for --schema)
  ...
  parsed_args_reset()                              // ENH-030 v1.1.0

  // Path split (invocation-path agnostic downstream):
  let err = if invoked_via_semantic_pipe:
              parse_from_schema_record(rec_ptr, rec_len)
            else:
              parse_argv(argv, argc)
  if err != ParsedArgs::ERR_OK { emit stderr diagnostic + exit code per I4 }

  // Dispatch by ID (same for both paths):
  let k_help = ParsedArgs::find_flag_by_id(StdVocab::STD_ID_HELP)
  if k_help != 32 {
    // M3-002: hand off to doc.
    let mut argv_slots : [u64; 2] = uninit @align(8)
    HelpBackend::fill_doc_argv(&argv_slots[0], MY_TOOL_NAME_PTR)
    exit(DocDispatch::doc_dispatch(&argv_slots[0], 2))
  }

  let k_schema = ParsedArgs::find_flag_by_id(StdVocab::STD_ID_SCHEMA)
  if k_schema != 32 {
    // M3-003: emit declared output schemas.
    let n = SchemaEmit::get_count()
    let mut i = 0
    while i < n {
      write_line(stdout_fd, SchemaEmit::get_name(i))
      i = i + 1
    }
    exit(0)
  }

  // Decode typed values (same as M2):
  let k_older = ParsedArgs::find_flag_by_id(100)
  if k_older != 32 {
    let (ok, secs) = Typed::parse_timespan(flag_values[k_older])
    ...
  }
```
