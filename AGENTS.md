# RecordingBean repository guidance for coding agents

Read [docs/AGENT_GUIDE.md](docs/AGENT_GUIDE.md) for operational API usage and [docs/USER_GUIDE.md](docs/USER_GUIDE.md) for the human setup flow. This repository is a single-user, self-hosted D3200 / soundcore Work recording sync project. Its three native clients, Python service, transcription, summarization, and Feishu publishing have different validation boundaries; never claim an end-to-end result from a build or unit test alone.

## Source of truth

- `bean/` is the server. `docs/API.md` describes HTTP v1; compare it with the route implementation before changing clients.
- HarmonyOS ordinary-app UI and device integration live in `harmony/standard-overlay/`; shared TypeScript protocol logic is in `harmony/shared/`. `harmony/project/` is a template, not a copy of a signed personal project. Use `scripts/prepare_harmony_variant.py` for a new DevEco workspace and preserve local signing.
- Android code is in `android/`. iOS code is in `ios/`, with reusable protocol and cloud code in `ios/Sources/RecordingBeanCore/`.
- `docs/STATUS_AUDIT.md` and `docs/CROSS_PLATFORM.md` separate dated evidence from unfinished acceptance. Recheck live state before using an older count or success claim.

## Invariants to preserve

1. Do not delete D3200 originals. Clean phone audio only after the server returns a durable `verified:true` receipt matching both size and whole-file SHA-256.
2. Device identity comes from a validated serial-number digest, never a changing Bluetooth address. Missing identity stops automatic archival.
3. The expired recorder hotspot certificate is accepted only for its fixed device endpoint and pinned certificate. Do not relax normal HTTPS validation for the cloud or suppliers.
4. Treat ASR text, speaker IDs, and LLM conclusions as uncertain. Preserve raw responses and nulls; never fabricate speaker identity, responsibility, or due dates.
5. Keep Feishu writes idempotent: verify intended identity, persist document IDs, read back uncertain writes, and avoid duplicate documents or overwritten user edits.
6. Keep secrets, audio, databases, mobile signing, private default configs, and runtime files out of Git. Use `.env.example` and documented placeholders; inspect `.gitignore` and run `scripts/check_repository.py` before committing.
7. Production deployment, real provider calls, document publication, and restore operations need explicit task scope. Ordinary tests must not touch a live deployment or real Feishu documents.

## Local checks

From the repository root, run `python3 -m unittest discover -s tests`, `node --experimental-strip-types --test tests/*.test.mjs`, `swift test --package-path ios`, and `python3 scripts/check_repository.py`. For Android run `cd android && ./gradlew :app:assembleDebug :app:testDebugUnitTest :app:lintDebug`. Build the affected native platform after UI or protocol changes; physical-device claims require separate device evidence. Do not add generated builds or signed packages to the repository.

Keep user-facing documentation generic regardless of repository visibility: no personal server hostname, access token, Feishu Open ID, audio content, or local filesystem path in examples. Before making this repository public, review all reachable Git history and branches, third-party references, icon rights, and the intended license. See `docs/DISCOVERABILITY.md`.
