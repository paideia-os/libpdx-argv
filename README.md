# libpdx-argv

paideia-os shared library: CLI argument parsing (text CLI + semantic-schema invocation)

## Status

**v1.0.0 — signed release.** All five milestones (M1..M5) closed.
See `STATUS.md` for the per-milestone rollup and `CHANGELOG.md` for
the 1.0 entry. Wave-level rubric lives at
`design/tooling/r49-r50-plan.md` §5.12 in the
[paideia-os](https://github.com/paideia-os/paideia-os) repo.

## Release

- `VERSION` — `1.0.0`
- `manifest.pdxsig` — dual-signed release manifest (both signature
  slots carry a `PENDING:` sentinel; populated in-place by
  `paideia-as release --sign` and by the `pkgs.paideia-os` mirror
  runner at admission time).
- `doc/libpdx-argv.pdxdoc` — `doc libpdx-argv` file per I7.
- `pkgs/mirror.entry` — admission entry the `pkgs.paideia-os`
  mirror runner consumes (once paideia-os meta issue
  `T-INFRA-001` lands).

## License

MIT — see LICENSE.
