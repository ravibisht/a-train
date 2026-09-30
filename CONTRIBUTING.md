# Contributing

- `python3 daemon/vpnsplitd.py --self-test` must print `self-test OK`. A daemon behaviour change ships
  with a self-test case that fails without it (the end-to-end fake routing table lives in `self_test`).
- `bash app/build.sh` must compile cleanly (Xcode or Command Line Tools with swiftc).
- Keep the invariants in `AGENTS.md`; each exists because it broke once.
- Never commit anything from `config/`, `backups/`, `dist/profile/` or build products; `.gitignore`
  already covers them.
- Company-specific defaults belong in `dist/profile/` on your machine, not in the tree.
