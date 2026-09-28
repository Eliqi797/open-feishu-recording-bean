# RecordingBean · Self-hosted D3200 recorder sync and AI meeting notes

**Sync D3200 / soundcore Work recordings to your own server, then create transcripts and meeting notes.** Native HarmonyOS, Android, and iOS apps control the recorder over Bluetooth and transfer audio through its temporary Wi-Fi hotspot. A self-hosted Python service stores the audio and can run ASR, LLM summarization, and Feishu / Lark Docs publishing.

~~~text
D3200 / soundcore Work → native mobile app → your server → speech-to-text → AI summary → Feishu / Lark Docs
~~~

[中文文档](README.md) · [Quick start](#quick-start) · [User guide](docs/USER_GUIDE.md) · [Agent start](AGENT_START.md) · [Validation status](docs/STATUS_AUDIT.md)

RecordingBean is an unofficial **single-user, self-hosted** project, not a public SaaS or a vendor app. This repository is currently private and requires access to clone. Device transfer, provider calls, and document publishing need separate validation in your own environment.

## Why I built it

I bought the D3200 to capture conversations and ideas whenever they happen. After recording, I still need to keep the original audio, check the transcript, and put useful notes into my own Feishu documents. I wanted to choose where recordings are stored, which ASR and LLM services process them, and how action items are organized. If an AI allowance or service plan changes, I want to keep using the recorder I already own.

RecordingBean began as my personal workflow: sync the recorder to my own server, verify the complete file, then transcribe, summarize, and file it when configured. I later added HarmonyOS, Android, and iOS clients and made provider settings configurable, preparing the project to be shared with others who have similar needs in the future.

## What it does

| Stage | Current implementation |
| --- | --- |
| Recorder and phone | Connection, battery and recording list; automatic sync; high-speed batch transfer over one recorder Wi-Fi connection with progress and speed. |
| Your server | Resumable chunk uploads, complete-file size and SHA-256 verification, protected playback. The phone clears its complete-audio cache only after verification; **D3200 originals remain untouched**. |
| Transcription and notes | Configurable NVIDIA NIM or compatible ASR, a Chat Completions-compatible LLM, separate processing states and stage retries. |
| Feishu / Lark | Creates and reads back meeting documents under the selected identity, with recording details, summary, transcript and tasks. Supports user tokens, app credentials, or server-side [lark-cli](https://github.com/larksuite/cli). |
| Live and native UI | Recording, Live and Settings tabs on HarmonyOS, Android and iOS; 2 / 5 / 10 / 20-second live windows, defaulting to 5 seconds. |

Speaker information depends on the actual ASR response; standalone Sortformer is not integrated. A live window size is not a guarantee of text latency. Read the [platform status](docs/CROSS_PLATFORM.md) and [validation audit](docs/STATUS_AUDIT.md) before treating a device path as verified.

## Quick start

Use Python 3.11+. Actual audio processing and compatible playback require FFmpeg; basic upload, playback and tests use the Python standard library.

~~~bash
git clone https://github.com/Eliqi797/d3200-recording-bean.git
cd d3200-recording-bean
git config core.hooksPath .githooks
python3 -m venv .venv
cp .env.example .env
.venv/bin/python -m bean.server --data data --port 8765
~~~

Open http://127.0.0.1:8765 and sign in with the access token created at data/access-token on first startup. The service binds to localhost by default. A phone needs your own HTTPS endpoint as described in the [deployment guide](docs/DEPLOYMENT.md); its localhost is not this computer.

For hosted NVIDIA NIM calls, install the optional client dependencies:

~~~bash
.venv/bin/python -m pip install -r requirements-nim.txt
~~~

Hosted NIM requires your own API access, but no local NVIDIA GPU or model download. Configure ASR, LLM and Feishu with the [configuration guide](docs/CONFIGURATION.md). You can validate upload, the verification receipt and protected playback before configuring any AI provider.

## Native apps and first recording

| Platform | Build from source | Recorder hotspot |
| --- | --- | --- |
| HarmonyOS | Follow the [HarmonyOS guide](harmony/README.md) with DevEco Studio and your own signing profile. | Grant Bluetooth and Wi-Fi permissions. |
| Android | Open android/ with Android Studio and Android SDK 36, then build the Debug app. | Accept the system Wi-Fi connection prompt. |
| iOS | Open ios/RecordingBean.xcodeproj in Xcode and select your Team; minimum iOS 17. | A free Personal Team joins the recorder hotspot manually, then returns to the app. |

There is no universal signed installer. See the [user guide](docs/USER_GUIDE.md) for platform setup.

Start with a **completed 30-second recording**: connect the D3200, check its list and battery, sync or tap High-speed Transfer, verify the cloud file's size and SHA-256 receipt, then play it back. If ASR, LLM and Feishu are enabled, review each result and read the document back in the intended account. A successful build, health check or upload status does not prove the whole workflow succeeded.

## For AI agents

If an agent is reading, deploying or changing this project, begin with [AGENT_START.md](AGENT_START.md). [AGENTS.md](AGENTS.md) contains coding invariants; the [agent guide](docs/AGENT_GUIDE.md) and [llms.txt](llms.txt) point to safe operations and API references. Do not infer real-device or Feishu success from tests or one completed stage.

## Documentation

| Task | Read |
| --- | --- |
| Installation, first sync and troubleshooting | [User guide](docs/USER_GUIDE.md) |
| Data flow and HTTP API | [Architecture](docs/ARCHITECTURE.md) · [API](docs/API.md) |
| ASR, LLM and Feishu options | [Integrations](docs/INTEGRATIONS.md) · [Configuration](docs/CONFIGURATION.md) |
| Typical questions and trade-offs | [Use cases](docs/USE_CASES.md) · [Official app or self-hosting](docs/ALTERNATIVES.md) |
| Platform differences and validation limits | [Cross-platform](docs/CROSS_PLATFORM.md) · [Status audit](docs/STATUS_AUDIT.md) |
| Deployment, backup and source maintenance | [Deployment](docs/DEPLOYMENT.md) · [Repository](docs/REPOSITORY.md) |
| Future publication review | [Discoverability](docs/DISCOVERABILITY.md) |

Git does not contain recordings, databases, API keys, Feishu authorization, signing material or private server settings. Keep the D3200 originals and review important AI output. Long locked-screen sessions, multi-hour recordings, overlapping speakers and independent backup recovery still require separate acceptance. This private repository has no open-source license yet; documentation changes do not make it public.
