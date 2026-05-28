# RFC-001 Handoff

Implemented RFC-001 surface migration in this repo.

## Summary

- Lexer/parser/AST now support:
  - `with [Cap <- expr] @ 'Scope { ... }`
  - per-binding `@ 'Scope`
  - `...spread`
  - `scope 'Child under 'Parent`
  - `capability Cap @ 'Scope`
  - expression-bodied top-level fns: `fn name(...) -> T = expr`
- Runtime maps `WithCaps` to the old capability-frame behavior.
- Diagnostics now mention `with`, spread, and missing scopes instead of old `provide`/`using`.
- Migrated interpreter fixtures, generated tests, playground examples, and live docs away from `provide`.
- Added RFC-focused tests in `dilang-interpreter/test/run_test.ml` for default scope, explicit per-binding scope, missing-scope error, nested shadowing, left-to-right capture, lifetime declarations, expression-bodied fn parsing, Wiring-value runtime error, and spread runtime error.

## Verification Already Done

- `git diff --check` passed.
- Static search found no old `provide`/`using` syntax in `dilang-interpreter/lib`, `dilang-interpreter/test`, or `playground`.
- Stage fixture and expect filenames match after renames.

## Still Needed

This machine has no `dune`, `ocaml`, `opam`, or `nix`, so these were not run:

```sh
cd /Users/gerberur/playground/dilang/dilang-interpreter
dune build
dune runtest
```

Run those checks, inspect any Menhir conflict changes against `lib/parser.conflicts`, and fix any compile/test failures.

## Caution

The worktree already had docs/RFC changes before this work. Do not revert unrelated user changes.
