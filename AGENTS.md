# Agent guide

## Start here

Read `PROGRESS.md` before planning work; it distinguishes tested behavior from unfinished milestones. Follow the user's latest instructions when priorities change.

## Repository and builds

- `vendor/McBopomofo` is a Git submodule pinned to an upstream MIT-licensed revision. Initialize with `git submodule update --init --recursive`. Keep upstream copyright and third-party notices.
- `scripts/prepare_upstream.py` creates and patches a disposable copy in `.build/McBopomofo`. Changes made only in `.build/` are discarded on the next build; put durable changes in tracked source or the preparation process. Do not silently change the pinned upstream revision.
- Use `./scripts/build.sh` and `./scripts/test.sh` for the current development build and upstream tests. The tests deliberately skip the online update API test. The app is ad-hoc signed and is not a notarized release.
- The installed test app uses a separate bundle ID, IMK connection, and default phrase directory. Never use the upstream installer: it targets the existing McBopomofo installation. `scripts/install.sh` refuses to replace an existing app; assess upgrades and preserve existing user input sources and data.

## Scope and safety

- M1 is a stable basic Zhuyin IME. Do not declare it complete until real input, candidate selection, focus transitions, and cross-app behavior in `docs/STAGE-0-1.md` are verified.
- For automatic bilingual input, read `docs/BILINGUAL-SPIKE.md`. `Sources/BilingualPrototype` is standalone research code, not connected to the IME. Preserve raw keys and composition state when testing ambiguous input.
- The original `data/english-words.txt` came from a third-party commercial app and remains in Git history. Do not reuse it. Current `data/` word lists are self-built from open sources by `tools/build_english_dict.py` and `tools/build_chinese_dict.py` (see README, 詞庫); redistribution rights of the derived files still deserve a check before release. Do not rewrite Git history without explicit authorization.
- `DESIGN.md` and `PLAN-reranker-backends.md` are historical proposals, not evidence of implemented features or verified platform behavior. AI and English prediction are not implemented.
- Never log typed content or send it off-device, with one owner-approved exception (2026-11-04): the opt-in local debug log (`DebugLog`: off by default, keys and routing decisions only, auto-off after 90 days (changed from 24h by the owner, 2026-11-05), 7-day/2 MB retention, owner-only file, never uploaded or committed; read it only when the owner asks). A second owner-approved exception (2026-11-04), for 知之 only: the sentence history (`SentenceHistory`: off by default until secure-field bypass is verified on the owner's Mac, AES-GCM with a Keychain key, 90-day retention, excluded from backups, no app name or URL, password tools and terminals excluded, never uploaded or committed; read it only when the owner asks). Text sent to the local helper `zhizhi-ai` goes over a pipe to a child process and is neither stored nor logged. Do not change the user's current input source or system settings without restoring them after testing; avoid overwriting user files.
