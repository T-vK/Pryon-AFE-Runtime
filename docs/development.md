# Contributing

Use Conventional Commits. Recommended scopes are `afe`, `pryon`, `mock`, `abi`, `examples`, `firmware`, `qemu`, `docs`, `build`, and `ci`.

Examples:

```text
feat(pryon): add JSONL event output
fix(afe): preserve partial input frames
docs(abi): document asp_process arguments
test(mock): add deterministic wake detection
```

Breaking changes require `!` or a `BREAKING CHANGE:` footer. Changes merged to `main` are analyzed automatically for the next semantic release.
