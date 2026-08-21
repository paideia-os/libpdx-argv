# tests/

Empty at M1 by design. The parse-correctness matrix — long/short/typed/
positional/mixed + clustered-short-flag rejection + typed-arg diagnostics
+ `--help` render round-trip — lands with `libpdx-argv.M4-001` per
`design/tooling/r49-r50-plan.md` §5.12 in paideia-os.

The M1 first-runnable example described in `design/architecture.md` §1 is
carried by the consumer tool (`pkg` or a small `examples/` binary added
alongside M2), not by this test tree.
