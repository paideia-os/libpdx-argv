# libpdx-argv — status

**Wave:** R49 shared library
**Current milestone:** M2 (core implementation) — CLOSED. Ready for M3
(semantic-pipe / audit integration: alt invocation via typed schema
record, `--help` back-end integration with `doc <tool>`, `--schema`
prints tool's declared output schemas).

## Milestone rollup

| ID              | Title                                                              | State  |
|-----------------|--------------------------------------------------------------------|--------|
| M1-001 (#1)     | scaffold + ParsedArgs struct + long-flag grammar                   | LANDED |
| M1-002 (#2)     | short-flag grammar one-per-hyphen (clustered -> reject)            | LANDED |
| M2-001 (#3)     | typed flag arguments (--older-than 7d, --size > 1MB)               | LANDED |
| M2-002 (#4)     | 9-flag standard vocabulary from I3                                 | LANDED |
| M2-003 (#5)     | positional-argument list handling (`--` sentinel, `:` separator)   | LANDED |

See `design/tooling/r49-r50-plan.md` §5.12 in paideia-os for the full
milestone breakdown (M1–M5) and cross-repo dependencies.

## Local layout

- `design/architecture.md` — internal spec (M1 record shape + state
  machine + M2 additions: FlagSpec, StdVocab, Typed, positional list).
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
- `caps.decl` — libpdx-argv requires no caps of its own.
- `tests/` — empty until `libpdx-argv.M4-001` lands the
  parse-correctness matrix.
- `.plans/` — per-milestone implementation notes.

## Consumer wiring (M2)

Every tool that uses libpdx-argv at M2 follows this init sequence:

```
_start:
  FlagSpec::reset()
  StdVocab::register_all()             // 9 std flags (IDs 1..9)
  FlagSpec::register(tool_name_a, kind_a, 100)   // tool-specific
  FlagSpec::register(tool_name_b, kind_b, 101)
  ...
  ParsedArgs::reset()
  let err = Parser::parse_argv(argv, argc)
  if err != ParsedArgs::ERR_OK { emit stderr diagnostic + exit code per I4 }

  // Dispatch by ID:
  let k_help = ParsedArgs::find_flag_by_id(StdVocab::STD_ID_HELP)
  if k_help != 32 { render_help(); exit(0) }

  // Decode typed values:
  let k_older = ParsedArgs::find_flag_by_id(100)
  if k_older != 32 {
    let (ok, secs) = Typed::parse_timespan(flag_values[k_older])
    ...
  }
```
