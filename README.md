# GuiAssert-ElevenLabs

ElevenLabs TTS plugin for [GuiAssert].  Implements GuiAssert's
`SpeechSynthesisProvider` contract on top of the commercial
[ElevenLabs v1 REST API](https://api.elevenlabs.io) — no Python, no
model weights, no GPU toolchain.  Pure-Nim HTTP client plus an
ffmpeg post-process to convert the returned MP3 into the 16-bit PCM
mono WAV shape every GuiAssert pipeline expects.

ElevenLabs is a commercial neural-TTS service distinguished by its
high voice fidelity and broad multilingual coverage relative to the
host-OS local TTS engines (`/usr/bin/say`, SAPI, espeak-ng) that
GuiAssert ships by default.  This plugin makes ElevenLabs available
as a *swappable* alternative whose voice quality and licence terms
differ from the local-OS defaults.

[GuiAssert]: ../GuiAssert/

## A different GuiAssert contract

Unlike the sibling talking-head plugins (`GuiAssert-SadTalker`,
`GuiAssert-Wav2Lip`, `GuiAssert-MuseTalk`, `GuiAssert-Did`,
`GuiAssert-HeyGen`, `GuiAssert-Synthesia`, `GuiAssert-Tavus`), this
plugin targets the M7 `SpeechSynthesisProvider` contract — a
*second* GuiAssert plugin contract introduced specifically so
consumers can swap among text-to-speech backends without affecting
the talking-head pipeline.

The contract lives in
`gui_assert/speech_synthesis/core` and mirrors the shape of the
`TalkingHeadProvider` contract: a `name` + `isAvailable` +
`synthesize` value type, a registry, and the same
`speechCacheKeyFor` / `applySpeechCache` helpers.

The non-pluggable `gui_assert/speech_synth.synthesize(text, path)`
dispatcher used by the existing marketing runner and other
consumers is unchanged.  It now routes through the new contract
internally (host-OS built-in provider, registered automatically),
which means every existing call site keeps working while the new
contract is exercised end-to-end on every legacy invocation.

## Layout

```
GuiAssert-ElevenLabs/
├── flake.nix                            nim + ffmpeg-full + openssl + cacert devShell (no Python)
├── gui_assert_elevenlabs.nimble         nimble package
├── src/
│   └── gui_assert_elevenlabs.nim        plugin implementation (SpeechSynthesisProvider)
└── tests/
    ├── fixtures/
    │   ├── README.md                    fixture provenance
    │   └── narration.wav                ~3.5 s test WAV (parity with sibling fixtures)
    └── televenlabs.nim                  pure + mock-server tests + `-d:elevenlabsLive` gated live test
```

## Cost of setup

| Resource     | Approx.                                                |
| ------------ | ------------------------------------------------------ |
| Disk         | None beyond Nim build artefacts                        |
| Network      | Per-render JSON + MP3 download, modest                 |
| Time         | First call ~seconds (ElevenLabs streams the response)  |
| Dollars      | **Starter $5/mo** (30K credits ≈ ~30 min of TTS, commercial-use rights), **Creator $22/mo**, **Pro $99/mo**, **Scale $330/mo**.  Renders are credit-metered within a plan. |
| API key      | Yes — `ELEVENLABS_API_KEY` env var                     |

Pricing is set by ElevenLabs; see [their pricing
page](https://elevenlabs.io/pricing) for current numbers and the
per-tier credit allowance.  The Starter tier's allowance is
intentionally small (~30 min); plan accordingly when wiring this
plugin into a CI pipeline.

## Setup

```sh
nix develop
export ELEVENLABS_API_KEY="..."   # from https://elevenlabs.io
```

No install script.  No model weights.  The `nix develop` shell
provisions Nim, ffmpeg (for MP3 -> WAV conversion + the mock-server
test's silent-MP3 fixture + ffprobe validation), OpenSSL, and a CA
bundle so TLS to `api.elevenlabs.io` works without user setup.

## Authentication

ElevenLabs authenticates with a custom `xi-api-key` HTTP header
(lowercase per their docs, raw key, no `Bearer ` / `Basic `
prefix):

```
xi-api-key: 0123abcd-your-elevenlabs-key
```

HTTP header names are case-insensitive on the wire, but
ElevenLabs's docs spec the lowercase form (`xi-api-key`) and this
plugin emits it verbatim.  The pure tests include regression guards
against accidental "fixes" that would prepend a `Bearer ` or
`Basic ` prefix.

## Wiring into a runner

```nim
import gui_assert/speech_synthesis
import gui_assert_elevenlabs

let reg = newDefaultSpeechRegistry()   # pre-registers the host-OS provider
registerElevenLabs(reg)                # now `elevenlabs` is also registered

var opts = SpeechSynthesisOpts(
  voiceId: some("21m00Tcm4TlvDq8ikWAM"),   # Rachel
  sampleRateHz: some(22050),
  cacheDir: some("/tmp/elevenlabs-cache"),
  providerSettings: %*{
    "model_id": "eleven_monolingual_v1",
    "stability": 0.5,
    "similarity_boost": 0.5,
    # api_key falls back to $ELEVENLABS_API_KEY
  },
)
synthesizeWith(reg, "elevenlabs",
              "Hello from GuiAssert ElevenLabs.",
              "/tmp/narration.wav", opts)
```

The legacy `speech_synth.synthesize(text, path)` proc continues to
work unchanged — it goes through the same registry under the hood
but selects the host-OS built-in (`say` / `sapi` / `espeak`)
instead of `elevenlabs`.  Consumers that want the local-OS voice
for some calls and ElevenLabs for others can build their own
registry and route per call.

### Configuration

All knobs live under `SpeechSynthesisOpts.providerSettings` (a
`JsonNode`), with environment-variable fallbacks where applicable.
The top-level `voiceId` / `sampleRateHz` fields on
`SpeechSynthesisOpts` are honoured first; provider-specific
settings layer on top.

| Setting | YAML key | Env fallback | Default | Purpose |
| --- | --- | --- | --- | --- |
| `api_key` | `api_key` | `ELEVENLABS_API_KEY` | _(none)_ | ElevenLabs API key. |
| `api_base` | `api_base` | _(none)_ | `https://api.elevenlabs.io` | API endpoint.  Override to point at a mock or staging server. |
| `voice_id` | top-level `voiceId` + fallback `voice_id` | _(none)_ | `21m00Tcm4TlvDq8ikWAM` (Rachel) | ElevenLabs voice identifier. |
| `model_id` | `model_id` | _(none)_ | `eleven_monolingual_v1` | ElevenLabs TTS model. |
| `stability` | `stability` | _(none)_ | `0.5` | Voice-stability slider, 0-1. |
| `similarity_boost` | `similarity_boost` | _(none)_ | `0.5` | Voice-similarity-boost slider, 0-1. |
| `sampleRateHz` | top-level `sampleRateHz` | _(none)_ | `22050` | Output WAV sample rate (driven by the post-ffmpeg conversion, not by the ElevenLabs response format). |

The provider name is `"elevenlabs"`.

## API flow

The provider performs exactly two steps per render (one HTTP call —
ElevenLabs has no polling step — plus the local ffmpeg conversion):

1. `POST /v1/text-to-speech/{voice_id}` — JSON body of the form:
   ```json
   {
     "text": "Hello, this is ElevenLabs.",
     "model_id": "eleven_monolingual_v1",
     "voice_settings": {
       "stability": 0.5,
       "similarity_boost": 0.5
     }
   }
   ```
   The response body is raw MP3 bytes (the default ElevenLabs
   format is `mp3_44100_128`).  No `Location` header, no polling,
   no envelope JSON.
2. `ffmpeg -i <mp3> -ar <sampleRateHz> -ac 1 -c:a pcm_s16le <wav>`
   — converts the MP3 to the 16-bit PCM mono RIFF WAV shape every
   GuiAssert pipeline (`speech_synth.synthesize`, talking-head
   plugins, the marketing runner) consumes.

Authentication uses the ElevenLabs-specific
`xi-api-key: <ELEVENLABS_API_KEY>` header on the POST.

## Caching

The plugin reuses GuiAssert's generic on-disk cache
(`applySpeechCache` + `speechCacheKeyFor`).  The cache key folds:

- the exact narration text,
- the canonical provider name (`elevenlabs`),
- the voice id,
- a SHA-1-prefixed salt over `(model_id, sample_rate, stability,
  similarity_boost)`.

Identical inputs short-circuit the POST entirely on the second
invocation.  This is doubly important here because every cache hit
avoids spending an ElevenLabs credit.

The mock-server test validates the cache-hit path: a second
`synthesize` call against the same inputs issues zero HTTP
requests.

## Tests

```sh
# Pure unit tests + mock-server integration test — no network.
nim c -r --threads:on --hints:off --path:src --path:../GuiAssert/src tests/televenlabs.nim

# Live end-to-end against api.elevenlabs.io — requires ELEVENLABS_API_KEY.
nim c -d:elevenlabsLive -r --threads:on --hints:off --path:src --path:../GuiAssert/src tests/televenlabs.nim
```

The `--threads:on` flag is required because the mock-server test
spawns a thread that drives `asyncdispatch.poll()` while the main
thread issues blocking `std/httpclient` calls.

The mock-server suite spins up a `std/asynchttpserver` on a random
localhost port, records every request the provider issues (method,
path, headers, body), and asserts:

- The single API request carries the `xi-api-key` header set to
  the test key (`DUMMY_KEY`) — raw, with no `Bearer ` prefix.
- `POST /v1/text-to-speech/{voice_id}` carries exactly the JSON
  shape ElevenLabs documents (top-level `text`, `model_id`, and a
  nested `voice_settings` object with `stability` +
  `similarity_boost`).
- ffprobe confirms the converted WAV is a valid 16-bit PCM mono
  RIFF WAV at the requested sample rate and the right duration.
- A second call hits the on-disk cache and issues zero HTTP
  traffic.
- Changing the narration text forces a fresh render (different
  cache key).

The live test fails the run if `ELEVENLABS_API_KEY` is missing —
per project policy, there are no graceful skips.  CI that does not
want to spend real ElevenLabs credit simply compiles without
`-d:elevenlabsLive`.

## License

MIT — see `LICENSE`.  ElevenLabs itself is a commercial service
governed by its own [terms of
service](https://elevenlabs.io/terms-of-use); the plugin only
speaks the public REST API.
