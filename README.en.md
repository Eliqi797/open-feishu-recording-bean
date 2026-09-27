# RecordingBean · D3200 recorder sync and AI meeting notes

[Chinese documentation](README.md)

RecordingBean is an unofficial, self-hosted sync project for the D3200 / soundcore Work recorder. Native apps for HarmonyOS, Android, and iOS connect over Bluetooth, transfer recordings over the recorder's temporary Wi-Fi hotspot, and upload them to your own Python server. The server can then use NVIDIA NIM or a compatible speech-to-text API, an LLM, and Feishu / Lark Docs to produce transcripts and meeting notes.

**Designed for one person running one service instance.** This is not a public SaaS product or an official soundcore, Feishu, or NVIDIA app. The repository uses the same URL regardless of visibility; see the [publication review](docs/DISCOVERABILITY.md) before making it public. Recordings, credentials, signing material, and server data must be stored outside Git.

## What it does

- Shows connection status, recorder battery level, and recordings in the HarmonyOS, Android, and iOS apps. The apps have Recording, Live, and Settings tabs, with light and dark appearance.
- Supports automatic sync after connection and a high-speed batch transfer action. One Wi-Fi hotspot connection can transfer multiple completed recordings; the app displays progress and transfer speed.
- Uploads in resumable chunks and verifies the full file by size and SHA-256 before clearing the phone's complete-audio cache. It **does not delete recordings from the D3200**.
- Uses a validated device-serial digest for archive identity so a changing Bluetooth address does not create another device archive.
- Supports live transcription in configurable 2, 5, 10, or 20 second windows; the default is 5 seconds. Window size is not the same as end-to-end text latency.
- Lets the owner configure ASR, LLM, Feishu, and transfer settings. A generated Feishu document can include recording metadata, a summary, transcript, and native checklist items.

Some paths have been tested on personal phones and a private server, but long locked-screen sessions, overlapping speakers, long recordings across all platforms, and independent backup recovery still need separate acceptance. Sortformer is not integrated. Keep the original recording and review AI output before relying on it. See the dated [status audit](docs/STATUS_AUDIT.md) and [cross-platform notes](docs/CROSS_PLATFORM.md).

## Get the source

The repository URL does not change with visibility. A private repository requires GitHub access; a public one can be cloned directly:

```bash
git clone https://github.com/Eliqi797/recording-bean.git
cd recording-bean
git config core.hooksPath .githooks
```

`bean/` and `web/` contain the Python service and web interface. `harmony/`, `android/`, and `ios/` contain the native clients; `deploy/` and `scripts/` contain deployment and maintenance tools. No personal server address, credential, or signed install package is included.

## Run the service locally

Use Python 3.11+ and FFmpeg. The base upload, playback, and tests use the Python standard library. Hosted NVIDIA NIM calls do **not** require a local NVIDIA GPU or model download; install `requirements-nim.txt` for those calls.

```bash
python3 -m venv .venv
cp .env.example .env
.venv/bin/python -m bean.server --data data --port 8765
```

Open `http://127.0.0.1:8765` and sign in with the access token created at `data/access-token` on first startup. The server binds to localhost by default. A phone needs your own HTTPS endpoint; its `localhost` does not refer to your computer. Follow the [deployment guide](docs/DEPLOYMENT.md) before exposing the service, and keep the upload port behind an HTTPS reverse proxy. To enable NIM, run:

```bash
.venv/bin/python -m pip install -r requirements-nim.txt
```

Configure your own ASR, LLM, and Feishu identity through `.env` or the app's Settings screen. App-saved server settings take priority over environment defaults on later processing stages. [Configuration reference](docs/CONFIGURATION.md) lists the fields. The service access token grants administrative access to this single-user deployment; do not share it or commit it.

## Install a native client

| Platform | Source installation | Recorder hotspot |
| --- | --- | --- |
| HarmonyOS | Prepare the ordinary app from [the HarmonyOS project guide](harmony/README.md) using DevEco Studio, its SDK, and your own signing profile. | Grant Bluetooth and Wi-Fi permissions when requested. |
| Android | Open `android/` in Android Studio with Android SDK 36, build `./gradlew :app:assembleDebug`, then install on your own phone. | Accept the system Wi-Fi connection prompt for batch transfer. |
| iOS | Open `ios/RecordingBean.xcodeproj` in Xcode, select your Team, and sign the app. Minimum iOS version: 17. | A free Personal Team uses manual hotspot joining in iPhone Wi-Fi settings; return to the app afterward. |

There is no universal signed installer. Platform permissions and firmware can affect device connections. A successful build is not proof that Bluetooth, hotspot transfer, ASR, and Feishu all work on your device.

## First end-to-end check

1. Record and stop a roughly 30-second sample on the D3200. Keep its original file.
2. Open the app's Recording tab, wake the D3200, scan, and connect. Confirm battery state and recording list.
3. Start automatic sync or tap High-speed Transfer. Accept hotspot access, watch download and upload progress, and wait for the server's verified receipt.
4. Check that the cloud copy plays. Inspect the separate ASR, speaker, summary, and Feishu stages; a saved audio file does not imply the document is ready.
5. If Feishu is configured, open the generated document in the intended account and check recording time, transcript, summary, and checklist items. Review the content against the original recording.

Without ASR, LLM, or Feishu credentials, you can still validate device transfer, durable upload, and protected playback. The web interface cannot replace native Bluetooth control or hotspot switching.

## For AI agents and contributors

Read [the agent operating guide](docs/AGENT_GUIDE.md), root [AGENTS.md](AGENTS.md), [architecture](docs/ARCHITECTURE.md), and [HTTP API](docs/API.md) before changing code or accessing a deployment. Do not infer end-to-end success from a build, a health check, or a completed processing status. Confirm the device, server receipt, provider response, and Feishu readback separately. Never print credentials or private recordings in diagnostics.

Useful local checks:

```bash
python3 -m unittest discover -s tests
node --experimental-strip-types --test tests/*.test.mjs
swift test --package-path ios
python3 scripts/check_repository.py
```

For Android, run `cd android && ./gradlew :app:assembleDebug :app:testDebugUnitTest :app:lintDebug`. Tests avoid real provider calls by default. See [repository maintenance](docs/REPOSITORY.md) and [publication readiness](docs/DISCOVERABILITY.md) for the boundary between source code, private deployment state, and future public visibility.

## Common questions

**Do I need an NVIDIA GPU?** No. The NVIDIA NIM option calls a hosted API. You still need your own API access and the client dependencies.

**Can I use only a browser?** The browser can view cloud data, but direct D3200 Bluetooth control and Wi-Fi transfer are native-app functions.

**Will making the repository public make the app immediately installable?** No. Each native platform still needs its SDK, signing, permissions, and your own server configuration. Public visibility also does not grant an open-source license by itself.

**Will the project show up in GitHub or AI search?** A private repository is visible only to authorized accounts. The English and Chinese READMEs, description, and Topics are prepared for discoverability after publication, but indexing and ranking are controlled by search platforms.
