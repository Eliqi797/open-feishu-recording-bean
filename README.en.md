# Open 飞书录音豆 · Self-hosted recorder sync and AI meeting notes

**Sync 飞书录音豆 recordings to your own server, then create transcripts and meeting notes.** Native HarmonyOS, Android, and iOS apps control the recorder over Bluetooth and transfer audio through its temporary Wi-Fi hotspot. A self-hosted Python service stores the audio and can run ASR, LLM summarization, and Feishu / Lark Docs publishing. See the [platform status](docs/CROSS_PLATFORM.md) for the supported hardware and validation limits.

~~~text
飞书录音豆 → native mobile app → your server → speech-to-text → AI summary → Feishu / Lark Docs
~~~

[中文文档](README.md) · [Quick start](#quick-start) · [User guide](docs/USER_GUIDE.md) · [Agent start](AGENT_START.md) · [Validation status](docs/STATUS_AUDIT.md)

Open 飞书录音豆 is an unofficial **single-user, self-hosted** project, not a public SaaS or a vendor app. This repository is currently private and requires access to clone. Device transfer, provider calls, and document publishing need separate validation in your own environment.

## Why I built it

I bought the 飞书录音豆 recorder to capture conversations and ideas whenever they happen. But [the official AI transcription and notes workflow has free or bundled allowances and paid membership options](https://www.feishu.cn/content/article/7597268954498763996). As my usage grows, I do not want to keep buying the official AI membership just to process recordings from hardware I already own. **That is why I built Open 飞书录音豆: to run my own processing workflow without requiring the official paid AI plan.**

My workflow syncs audio to my own server, verifies the complete file, then uses my chosen ASR and LLM services to create notes in my own Feishu documents. The project itself has no subscription fee. With an existing server and enough free API allowance, it can run without an additional payment for this workflow. Third-party APIs, cloud hosting, and domains may still cost money; **zero additional cost depends on the setup and usage**. I can keep using the recorder even if official allowances or plans change.

## What it does

| Stage | Current implementation |
| --- | --- |
| Recorder and phone | Connection, battery and recording list; automatic sync; high-speed batch transfer over one recorder Wi-Fi connection with progress and speed. |
| Your server | Resumable chunk uploads, complete-file size and SHA-256 verification, protected playback. The phone clears its complete-audio cache only after verification; **recorder originals remain untouched**. |
| Transcription and notes | Configurable NVIDIA NIM or compatible ASR, a Chat Completions-compatible LLM, separate processing states and stage retries. |
| Feishu / Lark | Creates and reads back meeting documents under the selected identity, with recording details, summary, transcript and tasks. Supports user tokens, app credentials, or server-side [lark-cli](https://github.com/larksuite/cli). |
| Live and native UI | Recording, Live and Settings tabs on HarmonyOS, Android and iOS; 2 / 5 / 10 / 20-second live windows, defaulting to 5 seconds. |

Speaker information depends on the actual ASR response; standalone Sortformer is not integrated. A live window size is not a guarantee of text latency. Read the [platform status](docs/CROSS_PLATFORM.md) and [validation audit](docs/STATUS_AUDIT.md) before treating a device path as verified.

## Quick start

Use Python 3.11+. Actual audio processing and compatible playback require FFmpeg; basic upload, playback and tests use the Python standard library.

~~~bash
git clone https://github.com/Eliqi797/open-feishu-recording-bean.git
cd open-feishu-recording-bean
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

Start with a **completed 30-second recording**: connect the recorder, check its list and battery, sync or tap High-speed Transfer, verify the cloud file's size and SHA-256 receipt, then play it back. If ASR, LLM and Feishu are enabled, review each result and read the document back in the intended account. A successful build, health check or upload status does not prove the whole workflow succeeded.

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

Git does not contain recordings, databases, API keys, Feishu authorization, signing material or private server settings. Keep the recorder originals and review important AI output. Long locked-screen sessions, multi-hour recordings, overlapping speakers and independent backup recovery still require separate acceptance. This private repository has no open-source license yet; documentation changes do not make it public.
