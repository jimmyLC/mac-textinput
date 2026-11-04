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
- Manual English mode is configurable, default Caps Lock.
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
- Candidates come from statistics, an idle local-AI pass filters them, and they are added directly, tagged "auto". Deleted words are never relearned. Entries may contain spaces, digits, and mixed Chinese/English. Generic import/export.
- Learning may store full sentences (owner decision): 90-day retention then statistics only, encrypted with a Keychain key, excluded from backups, password tools and terminals excluded by default, one-click pause, search and delete. Sentence history stores no app name or URL. Stays off until secure-field bypass is verified on a real device.

## App
One `/Applications` app embedding the IME; it installs, updates, and restores. Pages: home, dictionary, history, preferences, AI. It need not stay running.

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
