# libpdx-argv — status

**Wave:** R49 shared library
**Current milestone:** M3 (semantic-pipe / audit integration) — CLOSED.
Ready for M4 (parse-correctness matrix + clustered-short-flag rejection
tests + typed-arg-parse-error diagnostics + --help render round-trip
via doc).

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
- `tests/` — empty until `libpdx-argv.M4-001` lands the
  parse-correctness matrix.
- `.plans/` — per-milestone implementation notes.

## Consumer wiring (M3)

Every tool that uses libpdx-argv at M3 follows this init sequence.
Only the argv-vs-record branch (call out below) differs from the M2
shape; downstream dispatch is identical.

```
_start:
  FlagSpec::reset()
  StdVocab::register_all()             // 9 std flags (IDs 1..9)
  FlagSpec::register(tool_name_a, kind_a, 100)   // tool-specific
  FlagSpec::register(tool_name_b, kind_b, 101)
  ...
  SchemaEmit::reset()
  SchemaEmit::register(&SCHEMA_NAME_A)  // tool's declared output schemas
  SchemaEmit::register(&SCHEMA_NAME_B)  // (for --schema)
  ...
  ParsedArgs::reset()

  // Path split (invocation-path agnostic downstream):
  let err = if invoked_via_semantic_pipe:
              SchemaInvoke::parse_from_schema_record(rec_ptr, rec_len)
            else:
              Parser::parse_argv(argv, argc)
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
