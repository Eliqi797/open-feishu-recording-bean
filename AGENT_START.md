# RecordingBean — Agent start

RecordingBean is an unofficial, single-user, self-hosted workflow for D3200 / soundcore Work recordings. The hardware makes the recording; native HarmonyOS, Android and iOS apps move it to a Python service. The service stores the audio and, when configured, runs ASR, LLM summarization and Feishu / Lark Docs publication.

~~~text
D3200 → native phone app → verified cloud audio → ASR → speaker stage → LLM summary → Feishu document
~~~

The repository is private. Never assume that a local build, health check or staged task proves that a real device, provider or document has been validated.

## Choose an entry point

| Your task | Read first |
| --- | --- |
| Explain the product or help a person start | [README.md](README.md) or [README.en.md](README.en.md), then [user guide](docs/USER_GUIDE.md) |
| Change source code | [AGENTS.md](AGENTS.md), then [architecture](docs/ARCHITECTURE.md) and relevant tests |
| Inspect or operate a deployment | [Agent guide](docs/AGENT_GUIDE.md), [API](docs/API.md), [deployment](docs/DEPLOYMENT.md) |
| Configure providers or Feishu | [Integrations](docs/INTEGRATIONS.md) and [configuration](docs/CONFIGURATION.md) |
| Make a platform or acceptance claim | [Cross-platform status](docs/CROSS_PLATFORM.md) and [status audit](docs/STATUS_AUDIT.md); recheck live evidence |

## Non-negotiable boundaries

- Never delete a D3200 original. Clear phone audio only after a durable server receipt matches size and whole-file SHA-256.
- A changing Bluetooth address is not a device identity. Use the validated serial-number digest or stop automatic archival.
- Keep recordings, credentials, private endpoints, signing and provider responses out of Git and diagnostic output.
- The recorder hotspot's pinned-certificate exception applies only to that device endpoint; normal cloud HTTPS validation remains in place.
- Preserve unknown speakers and uncertain ASR/LLM conclusions as unknown. Do not invent names, owners or dates.
- Verify the intended Feishu identity before writing; read back an uncertain write instead of creating a duplicate document.
- Follow the user's authorization for live uploads, provider calls, Feishu writes, deployment and restore. Local tests do not authorize production changes.

## What counts as complete

For an end-to-end claim, verify separately: the completed D3200 file, mobile transfer, matching cloud file and receipt, actual ASR response, speaker stage if enabled, LLM result, Feishu document write, and document readback under the intended identity. Report missing or untested stages explicitly. The [agent guide](docs/AGENT_GUIDE.md) describes safe API queries and retry behavior.

This file is a navigation map. Repository coding rules live in [AGENTS.md](AGENTS.md); API behavior must be checked against [docs/API.md](docs/API.md) and the current implementation.
