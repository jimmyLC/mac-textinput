# 知之 Zhizhi: design (agreed with the owner, 2026-11-04)

A from-scratch rewrite replacing the McBopomofo-based ZhuyinLM. The goal is typing that flows: fewer re-selections and smooth Chinese/English mixing.

## Architecture
- All Swift; `vendor/` is removed at cutover. The self-built lexicon stays (its sources include McBopomofo MIT data: keep the notice).
- ID `com.jimmylc.inputmethod.Zhizhi`, data in `~/Library/Application Support/Zhizhi/`. Apple Silicon, macOS 14+. Personal use first, but no hard-coded paths and no Python dependency.
- `Zhizhi/` SwiftPM package: `ZhizhiCore` is the pure engine with no InputMethodKit, so it can be replayed and tested.

## Typing
- One composition buffer holding raw keys. Every key re-decodes the whole buffer into mixed segments, so a judgement can change until commit.
- Commit on Enter or sentence-ending punctuation, on focus change, and the front part when the buffer exceeds about 40 characters.
- Space: tone 1 while a syllable is unfinished; a literal space after English (stays in the buffer); a plain space when the buffer is empty. Space never opens candidates.
- Default judgement: Chinese first (a tone key always means Chinese; otherwise English needs 3+ letters, a common word, and no sensible Zhuyin reading). Settings can switch to habit-based or English first. Lone left Shift flips the segment before the cursor.
- Caps Lock means capitals and passes keys to the app; Shift under Caps Lock types lowercase. Shift+letter while composing is a capital and reads as English. A lone left Shift with nothing composing toggles manual English mode (changed 2026-11-04 after real typing: Caps Lock as the switch left Shift unusable, because macOS stays uppercase under Caps Lock + Shift). The switching key stays configurable.
- Zhuyin components in any order; tones may be omitted only when the syllables form a common word (a lone syllable still needs its tone). Standard layout only. One wrong tone is tolerated by the engine.
- Numbers: a digit run that is not sensible Zhuyin is a number; Option+digit and the numpad are always digits. Tokens with `://`, `@`, or letters joined by `.-_/` are English as a whole. Punctuation width follows the preceding text (configurable).
- Auto space between Chinese and English in both directions (can be turned off). Problem apps use a floating composition window; the list comes from testing.

## Selecting and completing
- Down arrow opens candidates; digits select; picks are locked against re-decoding and AI. Vertical, translucent, 9 per page by default.
- Tab completes only English and personal-dictionary entries (from the 2nd letter or 2nd syllable, one offer at a time); general Chinese gets no Tab. English misspellings are offered, never auto-fixed.
- Esc only closes candidates (clearing the buffer is an option).

## Local AI
- After a pause, silently corrects uncommitted, unlocked characters above a conservative threshold; can be turned off. Changed characters get a faint mark for about 1 second; Cmd-Z restores and locks.
- Qwen2.5-1.5B-4bit in a separate Swift/MLX helper; key handling never waits for it; unloaded when idle. Download is offered at first launch and in settings. Without a model, typing still works.

## Dictionary and learning
- Candidates come from statistics and are added directly, tagged "auto": an unknown English word committed 3 times (never a likely misspelling), or characters picked side by side twice. Picking a known word raises it among its homophones, within a limit, and adds no entry. Counts are salted hashes, so a word below its threshold cannot be read from disk. Deleted words are never relearned. Entries may contain spaces, digits, and mixed Chinese/English. The dictionary is a plain TSV in Application Support, which covers generic import/export.
- The agreed idle AI filter is not built (changed 2026-11-04): these candidates are words the user explicitly chose or typed repeatedly, and homophone scoring would reject exactly the rare names they want. Revisit if auto entries turn out noisy.
- Learning may store full sentences (owner decision): 90-day retention then statistics only, encrypted with a Keychain key, excluded from backups, password tools and terminals excluded by default, one-click pause, search and delete. Sentence history stores no app name or URL. Stays off until secure-field bypass is verified on a real device.

## App
One `/Applications` app embedding the IME; it installs, updates, and restores. Pages: home, dictionary, history, preferences, AI. It need not stay running.
- `知之.app` (`com.jimmylc.Zhizhi`) carries `Zhizhi.app` in its resources and copies it to `~/Library/Input Methods`, keeping the previous copy so one click restores it. Each build has its own `CFBundleVersion`, which is how it spots an older install. `scripts/build-app.sh`, `scripts/install-app.sh`.
- Settings live in the input method's defaults domain, and the dictionary in its TSV files. The App changes them and posts a distributed notification, so the input method follows without a restart.
- The model downloads only on the owner's click, at a pinned Hugging Face revision, with every file's SHA-256 checked before it counts as installed.
- Not built: habit-based language judgement (the App offers Chinese first or English first), simplified output, and a real-time list of problem apps. The sentence history key is created in the Keychain by whichever process asks first, so with ad-hoc signing the other may trigger a macOS permission prompt, again after each rebuild.

Kept from the old IME: candidate window, full/half-width punctuation, symbol table, cursor movement in the buffer. Simplified output later. Dropped: associated phrases, macros, plain Bopomofo mode, rare features.

## Gates before replacing the old IME
1. Replaying the owner's key log: the 11 English misjudgements are gone.
2. About 500 test sentences: whole-sentence accuracy target 90% (baseline 71%). The target is an estimate; if unreachable, add word-bigram statistics from Traditional Chinese Wikipedia (license check before any public release).
3. Key handling p95 at most 10 ms.
4. Three days of real use: backspace share below the old IME's roughly 7%.
5. LINE, Chrome, Claude, VS Code, Outlook: no eaten characters.

## Stages
Pure engine, then IME, then local AI and learning, then App, then the 3-day trial (old and new coexist only during the trial, then the old one is removed; the personal dictionary and user phrases are imported). Each stage is a branch; merging and pushing need owner approval.

## Open risks
Swift MLX scoring is unproven; only macOS 27 is testable here; secure-field bypass is unverified; the Qwen license and the name need checking before release. Icon: white background, black Z with a small I (redrawn, not copied).
