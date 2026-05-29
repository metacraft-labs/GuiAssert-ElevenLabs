## ElevenLabs TTS plugin for GuiAssert.
##
## Implements GuiAssert's `SpeechSynthesisProvider` contract on top of
## the commercial ElevenLabs v1 REST API
## (https://api.elevenlabs.io).  Like the sibling commercial talking-
## head plugins (D-ID, HeyGen, Synthesia, Tavus) this is a pure-Nim
## HTTP client — no Python, no model weights, no GPU toolchain.
##
## Unlike the talking-head plugins, ElevenLabs targets a *different*
## GuiAssert contract: the M7 `SpeechSynthesisProvider` interface
## introduced alongside this plugin.  The native local TTS dispatcher
## in `gui_assert/speech_synth` is unchanged and continues to drive
## the host-OS `say` / SAPI / espeak-ng backends; this plugin makes
## ElevenLabs available as a swappable alternative whose voice
## quality and language coverage are typically higher than the
## host-OS defaults.
##
## ## Wire shape
##
##   * `elevenlabsProvider()` builds a `SpeechSynthesisProvider`
##     value with `name = "elevenlabs"`, an `isAvailable` check
##     (is `ELEVENLABS_API_KEY` set?), and a `synthesize` proc that
##     performs the POST + MP3-to-WAV conversion.
##   * `registerElevenLabs(reg)` is the one-liner plugin registration
##     entry point.
##
## ## API flow
##
##   1. `POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}` —
##      JSON body of the form
##      ```json
##      {
##        "text": "Hello, this is ElevenLabs.",
##        "model_id": "eleven_multilingual_v2",
##        "voice_settings": {
##          "stability": 0.5,
##          "similarity_boost": 0.5
##        }
##      }
##      ```
##      The response body is raw audio bytes (MP3 by default, or PCM
##      when an explicit `output_format=pcm_16000` query parameter is
##      set).  There is *no* polling step — the audio is returned
##      synchronously.
##   2. `ffmpeg -i <mp3> -ar <rate> -ac 1 -c:a pcm_s16le <wav>` —
##      converts the returned MP3 into the 16-bit PCM mono WAV shape
##      every other GuiAssert pipeline (`speech_synth.synthesize`,
##      the talking-head plugins, the marketing runner) expects.
##
## ## Authentication
##
## ElevenLabs authenticates with a custom `xi-api-key` HTTP header
## (lowercase per their docs, raw key, no `Bearer ` / `Basic `
## prefix).  Reads the key from `opts.providerSettings.api_key`,
## falling back to `$ELEVENLABS_API_KEY`.

import std/[json, options, os, osproc, streams, strutils]
import std/[httpclient, sha1]

import gui_assert/speech_synthesis
import gui_assert/emotive

type
  ElevenLabsError* = object of SpeechSynthesisError
    ## Raised by the low-level HTTP / ffmpeg entry points.  Subclasses
    ## `SpeechSynthesisError` so the generic dispatch in
    ## `gui_assert/speech_synthesis` can catch it uniformly.

const
  ProviderName* = "elevenlabs"
  DefaultElevenLabsApiBase* = "https://api.elevenlabs.io"
  DefaultElevenLabsVoiceId* = "21m00Tcm4TlvDq8ikWAM"
    ## "Rachel" — the default English voice documented in the
    ## ElevenLabs quick-start.
  DefaultElevenLabsModelId* = "eleven_multilingual_v2"
  DefaultStability* = 0.5
  DefaultSimilarityBoost* = 0.5
  ApiKeyEnvVar* = "ELEVENLABS_API_KEY"
  ApiBaseSetting* = "api_base"
  ApiKeySetting* = "api_key"
  ModelIdSetting* = "model_id"
  StabilitySetting* = "stability"
  SimilarityBoostSetting* = "similarity_boost"

# ---------------------------------------------------------------------------
# Pure helpers — testable without any network access.
# ---------------------------------------------------------------------------

proc elevenlabsAuthHeader*(apiKey: string): HttpHeaders =
  ## Build the auth header table ElevenLabs expects.  ElevenLabs uses
  ## a custom `xi-api-key` header (NOT HTTP Basic auth, NOT a Bearer
  ## token).  The docs spec the lowercase header name; we emit it
  ## verbatim even though HTTP header names are case-insensitive on
  ## the wire.  Pinned alongside `Content-Type: application/json`
  ## because every authenticated request from this plugin sends a
  ## JSON body.
  newHttpHeaders({"xi-api-key": apiKey, "Content-Type": "application/json"})

proc buildTtsBody*(text, modelId: string;
                  stability = DefaultStability,
                  similarityBoost = DefaultSimilarityBoost): JsonNode =
  ## Construct the JSON body for
  ## `POST /v1/text-to-speech/{voice_id}`.  Mirrors the documented v1
  ## shape exactly:
  ##
  ##   * `text` — required.
  ##   * `model_id` — required.
  ##   * `voice_settings` — required by ElevenLabs's voice-tuning
  ##     surface; defaults match the quick-start values.
  result = %*{
    "text": text,
    "model_id": modelId,
    "voice_settings": {
      "stability": stability,
      "similarity_boost": similarityBoost
    }
  }

proc resolveApiKey*(opts: SpeechSynthesisOpts): string =
  ## Order of precedence: `opts.providerSettings.api_key`, then the
  ## `$ELEVENLABS_API_KEY` env var, then "" (signalling
  ## unavailability).
  if not opts.providerSettings.isNil and opts.providerSettings.kind == JObject:
    let n = opts.providerSettings{ApiKeySetting}
    if not n.isNil and n.kind == JString and n.getStr.len > 0:
      return n.getStr
  result = getEnv(ApiKeyEnvVar)

proc resolveApiBase*(opts: SpeechSynthesisOpts): string =
  ## Order of precedence: `opts.providerSettings.api_base`, then the
  ## `DefaultElevenLabsApiBase` constant.  Trailing slashes are
  ## stripped so downstream string-concatenation stays predictable.
  var base = DefaultElevenLabsApiBase
  if not opts.providerSettings.isNil and opts.providerSettings.kind == JObject:
    let n = opts.providerSettings{ApiBaseSetting}
    if not n.isNil and n.kind == JString and n.getStr.len > 0:
      base = n.getStr
  while base.endsWith('/'):
    base.setLen(base.len - 1)
  result = base

proc resolveStringSetting(opts: SpeechSynthesisOpts,
                         key, default: string): string =
  if not opts.providerSettings.isNil and opts.providerSettings.kind == JObject:
    let n = opts.providerSettings{key}
    if not n.isNil and n.kind == JString and n.getStr.len > 0:
      return n.getStr
  result = default

proc resolveModelId*(opts: SpeechSynthesisOpts): string =
  resolveStringSetting(opts, ModelIdSetting, DefaultElevenLabsModelId)

proc resolveFloatSetting(opts: SpeechSynthesisOpts,
                        key: string, default: float): float =
  if not opts.providerSettings.isNil and opts.providerSettings.kind == JObject:
    let n = opts.providerSettings{key}
    if not n.isNil:
      case n.kind
      of JFloat: return n.getFloat
      of JInt: return float(n.getInt)
      else: discard
  result = default

proc resolveStability*(opts: SpeechSynthesisOpts): float =
  resolveFloatSetting(opts, StabilitySetting, DefaultStability)

proc resolveSimilarityBoost*(opts: SpeechSynthesisOpts): float =
  resolveFloatSetting(opts, SimilarityBoostSetting, DefaultSimilarityBoost)

proc resolveVoiceId*(opts: SpeechSynthesisOpts): string =
  ## Honours `opts.voiceId` first (top-level shape), then
  ## `opts.providerSettings.voice_id`, then the default Rachel voice.
  if opts.voiceId.isSome and opts.voiceId.get.len > 0:
    return opts.voiceId.get
  resolveStringSetting(opts, "voice_id", DefaultElevenLabsVoiceId)

# ---------------------------------------------------------------------------
# HTTP client construction.
# ---------------------------------------------------------------------------

proc newElevenLabsHttpClient*(apiKey: string,
                             timeoutMs = 120_000): HttpClient =
  ## Build an `HttpClient` pre-configured with the ElevenLabs
  ## `xi-api-key` header.  We pin `Connection: close` so each call
  ## opens a fresh TCP socket — this sidesteps the same
  ## `std/asynchttpserver` keep-alive race the sibling commercial
  ## talking-head plugins document.  We also set `Accept` to the
  ## documented MP3 mime type so the server picks the right
  ## body shape; ElevenLabs falls back to MP3 when the header is
  ## absent, but pinning it explicitly is more defensive.
  let headers = newHttpHeaders({
    "xi-api-key": apiKey,
    "Accept": "audio/mpeg",
    "Content-Type": "application/json",
    "User-Agent":
      "GuiAssert-ElevenLabs/0.1 (+https://github.com/metacraft-labs/GuiAssert)",
    "Connection": "close",
  })
  result = newHttpClient(timeout = timeoutMs, headers = headers)

proc closeQuietly(client: HttpClient) =
  try: client.close()
  except CatchableError: discard

# ---------------------------------------------------------------------------
# Low-level HTTP entry point.
# ---------------------------------------------------------------------------

proc raiseHttp(prefix: string, resp: Response) {.noreturn.} =
  ## Helper for surfacing non-2xx HTTP responses with body context.
  var body = ""
  try: body = resp.body
  except CatchableError: discard
  let excerpt =
    if body.len > 800: body[0 ..< 800] & " ...(truncated)"
    else: body
  raise newException(ElevenLabsError,
    prefix & ": HTTP " & resp.status & "\n" & excerpt)

proc requestTts*(apiKey, apiBase, voiceId, modelId, text: string;
                outputBytesPath: string): int =
  ## `POST /v1/text-to-speech/{voice_id}` with the documented JSON
  ## body.  Writes the raw audio response (MP3 by default) to
  ## `outputBytesPath` and returns the byte count.  Raises
  ## `ElevenLabsError` on non-2xx responses.
  ##
  ## Uses the default `voice_settings` (stability + similarity_boost
  ## both 0.5).  Callers that need bespoke tuning can build their
  ## own body via `buildTtsBody` and POST through a custom HTTP
  ## client; this entry point covers the common case.
  let client = newElevenLabsHttpClient(apiKey)
  try:
    let url = apiBase & "/v1/text-to-speech/" & voiceId
    let body = buildTtsBody(text, modelId)
    let resp = client.request(url, httpMethod = HttpPost, body = $body)
    if not resp.code.is2xx:
      raiseHttp("POST /v1/text-to-speech/" & voiceId, resp)
    let outParent = outputBytesPath.parentDir()
    if outParent.len > 0 and not dirExists(outParent):
      createDir(outParent)
    let raw = resp.body
    writeFile(outputBytesPath, raw)
    if not fileExists(outputBytesPath) or getFileSize(outputBytesPath) == 0:
      raise newException(ElevenLabsError,
        "ElevenLabs returned 2xx but no bytes were written at " &
        outputBytesPath)
    result = raw.len
  finally:
    closeQuietly(client)

proc convertMp3ToWav*(mp3Path, wavPath: string, sampleRateHz: int) =
  ## Convert an MP3 file to a 16-bit PCM mono RIFF WAV at
  ## `sampleRateHz`.  Uses ffmpeg's standard `-c:a pcm_s16le -ac 1
  ## -ar <rate>` flag set.  Looks up ffmpeg via `$FFMPEG_BIN` then
  ## `PATH`; raises `ElevenLabsError` when neither resolves.
  if not fileExists(mp3Path):
    raise newException(ElevenLabsError,
      "convertMp3ToWav: source MP3 not found: " & mp3Path)
  var ffmpeg = getEnv("FFMPEG_BIN")
  if ffmpeg.len == 0 or not fileExists(ffmpeg):
    ffmpeg = findExe("ffmpeg")
  if ffmpeg.len == 0:
    raise newException(ElevenLabsError,
      "ffmpeg not on PATH; cannot convert ElevenLabs MP3 -> WAV.")
  let outParent = wavPath.parentDir()
  if outParent.len > 0 and not dirExists(outParent):
    createDir(outParent)
  if fileExists(wavPath):
    removeFile(wavPath)
  let p = startProcess(
    command = ffmpeg,
    args = @[
      "-y", "-hide_banner", "-loglevel", "error",
      "-i", mp3Path,
      "-ar", $sampleRateHz,
      "-ac", "1",
      "-c:a", "pcm_s16le",
      wavPath,
    ],
    options = {poStdErrToStdOut}
  )
  let logTxt = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  if code != 0:
    raise newException(ElevenLabsError,
      "ffmpeg MP3 -> WAV conversion failed (" & $code & "): " & logTxt)
  if not fileExists(wavPath) or getFileSize(wavPath) == 0:
    raise newException(ElevenLabsError,
      "ffmpeg reported success but produced no WAV at " & wavPath)

# ---------------------------------------------------------------------------
# Provider integration. Glues the HTTP + ffmpeg layers to the
# `SpeechSynthesisProvider` contract.
# ---------------------------------------------------------------------------

proc elevenlabsIsAvailable*(): bool {.gcsafe.} =
  ## True iff an ElevenLabs API key is set in the environment.  We
  ## can't check the per-call `opts.providerSettings.api_key` here
  ## because `isAvailable` is parameterless by contract; the
  ## provider's `synthesize` proc re-resolves the key (including the
  ## YAML override path) and raises a clear error if the resolved
  ## key is empty.
  getEnv(ApiKeyEnvVar).len > 0

proc elevenlabsCacheSalt*(modelId: string; sampleRateHz: int;
                         stability, similarityBoost: float): string =
  ## Folds the ElevenLabs-specific tuning knobs (model_id +
  ## sample-rate + voice settings) into the cache-key sample-rate
  ## slot via a SHA-1 prefix.  Two calls that differ only in
  ## stability / similarity_boost therefore produce different cache
  ## entries — identical inputs short-circuit the API call.
  let mix = modelId & "|" & $sampleRateHz & "|" &
            formatFloat(stability, ffDecimal, 3) & "|" &
            formatFloat(similarityBoost, ffDecimal, 3)
  let d = secureHash(mix)
  let full = $d
  result = full[0 ..< 16].toLowerAscii

proc elevenlabsSynthesize(text, outputWavPath: string,
                         opts: SpeechSynthesisOpts) {.gcsafe.} =
  ## `synthesize` callback for the ElevenLabs plugin.  Implements
  ## the documented v1 POST -> MP3 -> WAV pipeline with the on-disk
  ## cache wrapping every call.
  if text.len == 0:
    raise newException(ElevenLabsError,
      "elevenlabs provider: refusing to synthesize an empty " &
      "narration string.")
  let apiKey = resolveApiKey(opts)
  if apiKey.len == 0:
    raise newException(ElevenLabsError,
      "elevenlabs provider: API key not set. Either export " &
      "ELEVENLABS_API_KEY=<key> or pass it via " &
      "SpeechSynthesisOpts.providerSettings.api_key.")
  let apiBase = resolveApiBase(opts)
  let voiceId = resolveVoiceId(opts)
  let modelId = resolveModelId(opts)
  let stability = resolveStability(opts)
  let similarityBoost = resolveSimilarityBoost(opts)
  let sampleRate = effectiveSampleRateHz(opts)

  let cacheDir = effectiveSpeechCacheDir(opts)
  if not dirExists(cacheDir):
    createDir(cacheDir)
  let salt = elevenlabsCacheSalt(modelId, sampleRate,
                                stability, similarityBoost)
  let key = speechCacheKeyFor(text, ProviderName, voiceId, salt)

  let outParent = outputWavPath.parentDir()
  if outParent.len > 0 and not dirExists(outParent):
    createDir(outParent)

  let generator = proc() =
    # POST -> raw MP3 in a temp file -> ffmpeg conversion -> final WAV.
    let mp3Path = cacheDir / (key & ".mp3")
    if fileExists(mp3Path): removeFile(mp3Path)
    discard requestTts(apiKey, apiBase, voiceId, modelId, text, mp3Path)
    convertMp3ToWav(mp3Path, outputWavPath, sampleRate)

  {.cast(gcsafe).}:
    discard applySpeechCache(cacheDir, key, outputWavPath, generator)

# ---------------------------------------------------------------------------
# Capabilities + emotive translation + discovery + dry-run
# ---------------------------------------------------------------------------

const ElevenLabsCapabilities* = ProviderCapabilities(
  supportsEmotion: false,           ## not directly; emotion baked into voice
  supportsHeadMotion: false,
  supportsExpressionScale: false,
  supportsGreenScreen: false,
  supportsTransparentBg: false,
  supportsAudioInput: false,
  supportsTextInput: true,
  supportsVoiceTuning: true,        ## stability + similarity_boost + style
  supportsGestures: false,
  supportsEyeContact: false,
  supportedEmotions: @[],
)

proc emotiveToProviderSettings*(c: CommonEmotiveConfig;
                                base: JsonNode = nil): JsonNode =
  ## Project a `CommonEmotiveConfig` onto the flat providerSettings
  ## dialect this plugin understands (`stability`,
  ## `similarity_boost`, `style`, `use_speaker_boost`).  Caller-set
  ## values in `base` win.
  ##
  ## Intensity acts as a *style* nudge — the higher the intensity,
  ## the more the model is allowed to deviate from a flat read, so
  ## it's mapped onto `style` when the consumer hasn't supplied a
  ## value explicitly.
  result = if base.isNil or base.kind != JObject: newJObject() else: base
  if c.voiceStability.isSome:
    setIfMissing(result, "stability", %c.voiceStability.get)
  if c.voiceSimilarityBoost.isSome:
    setIfMissing(result, "similarity_boost",
                 %c.voiceSimilarityBoost.get)
  if c.voiceStyle.isSome:
    setIfMissing(result, "style", %c.voiceStyle.get)
  elif c.intensity.isSome:
    setIfMissing(result, "style", %c.intensity.get)
  if c.useSpeakerBoost.isSome:
    setIfMissing(result, "use_speaker_boost", %c.useSpeakerBoost.get)

proc parseGenderField(node: JsonNode): Gender =
  if node.isNil or node.kind != JString: return gUnspecified
  parseGender(node.getStr)

proc listVoices*(apiKey: string;
                 apiBase: string = DefaultElevenLabsApiBase):
    seq[AvatarInfo] =
  ## `GET /v1/voices` — voice catalogue available on the supplied
  ## account.  Voice metadata is normalised onto `AvatarInfo` so
  ## `matchPreferredAvatar` works against voices the same way it
  ## works against avatars on the sibling talking-head plugins.
  result = @[]
  if apiKey.len == 0:
    raise newException(ElevenLabsError,
      "listVoices: ELEVENLABS_API_KEY is required")
  let client = newElevenLabsHttpClient(apiKey)
  try:
    let resp = client.request(apiBase & "/v1/voices",
                              httpMethod = HttpGet)
    if not resp.code.is2xx:
      raiseHttp("GET /v1/voices", resp)
    let parsed = parseJson(resp.body)
    if parsed.kind != JObject or not parsed.hasKey("voices"): return
    let lst = parsed["voices"]
    if lst.kind != JArray: return
    for it in lst.items:
      if it.kind != JObject: continue
      var a = AvatarInfo()
      a.id = it{"voice_id"}.getStr("")
      a.name = it{"name"}.getStr("")
      a.description = it{"description"}.getStr("")
      a.previewUrl = it{"preview_url"}.getStr("")
      if it.hasKey("labels") and it["labels"].kind == JObject:
        let lab = it["labels"]
        if lab.hasKey("gender") and lab["gender"].kind == JString:
          a.gender = parseGender(lab["gender"].getStr)
        for k, v in lab:
          if k == "gender": continue
          if v.kind == JString: a.tags.add v.getStr
      result.add a
  finally:
    closeQuietly(client)

# Backwards-compatible alias mirroring the talking-head plugins.
proc listAvatars*(apiKey: string;
                  apiBase: string = DefaultElevenLabsApiBase):
    seq[AvatarInfo] {.inline.} =
  listVoices(apiKey, apiBase)

proc dryRunValidate*(opts: SpeechSynthesisOpts;
                     prefs: AvatarPreferences = AvatarPreferences()):
    DryRunReport =
  ## Validate locally + against the live ElevenLabs voice catalogue:
  ## API key presence, voice id existence, and — when `prefs` is
  ## non-empty — whether any preferred voice matches the live list.
  result = newDryRunReport("elevenlabs")
  let apiKey = resolveApiKey(opts)
  if apiKey.len == 0:
    result.addIssue(drError, "api_key",
      "ELEVENLABS_API_KEY is not set (or providerSettings.api_key is empty)")
    return
  let apiBase = resolveApiBase(opts)
  var voiceId = resolveVoiceId(opts)
  var available: seq[AvatarInfo] = @[]
  try:
    available = listVoices(apiKey, apiBase)
  except CatchableError as e:
    result.addIssue(drWarning, "voices",
      "could not list voices: " & e.msg)
  if prefs.preferred.len > 0 and available.len > 0:
    let m = matchPreferredAvatar(prefs, "elevenlabs", available)
    if m.isSome:
      voiceId = m.get.id
    else:
      result.addIssue(drWarning, "avatar_preferences",
        "no preferred voice matched; using opts default '" & voiceId & "'")
  if available.len > 0:
    var hit = false
    for v in available:
      if v.id == voiceId:
        hit = true; break
    if not hit:
      result.addIssue(drError, "voice_id",
        "voice '" & voiceId & "' is not in the account's voice list " &
        "(deprecated / paid-only / typo)")

proc elevenlabsProvider*(): SpeechSynthesisProvider =
  ## Build the ElevenLabs provider value with production defaults.
  result = SpeechSynthesisProvider(
    name: ProviderName,
    isAvailable: elevenlabsIsAvailable,
    synthesize: elevenlabsSynthesize,
  )

proc registerElevenLabs*(reg: SpeechSynthesisRegistry) =
  ## One-liner plugin entry point.  Callers do:
  ##
  ## ```nim
  ## import gui_assert/speech_synthesis
  ## import gui_assert_elevenlabs
  ##
  ## let reg = newDefaultSpeechRegistry()
  ## registerElevenLabs(reg)
  ## synthesizeWith(reg, "elevenlabs", text, wavPath, opts)
  ## ```
  reg.registerSpeechProvider(elevenlabsProvider())
