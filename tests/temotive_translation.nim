## Pure tests for ElevenLabs emotive translation + capability self-description.

import std/[json, options, unittest]
import gui_assert/speech_synthesis, gui_assert/emotive
import gui_assert_elevenlabs

suite "ElevenLabs emotiveToProviderSettings":

  test "voice tuning fields project verbatim onto providerSettings":
    var c = initEmotive()
    c.voiceStability = some(0.3)
    c.voiceSimilarityBoost = some(0.85)
    c.voiceStyle = some(0.5)
    c.useSpeakerBoost = some(true)
    let j = emotiveToProviderSettings(c)
    check j["stability"].getFloat == 0.3
    check j["similarity_boost"].getFloat == 0.85
    check j["style"].getFloat == 0.5
    check j["use_speaker_boost"].getBool == true

  test "intensity falls through to `style` when voiceStyle is unset":
    var c = initEmotive()
    c.intensity = some(0.7)
    let j = emotiveToProviderSettings(c)
    check j["style"].getFloat == 0.7

  test "explicit voiceStyle wins over intensity":
    var c = initEmotive()
    c.intensity = some(0.7)
    c.voiceStyle = some(0.2)
    let j = emotiveToProviderSettings(c)
    check j["style"].getFloat == 0.2

  test "missing fields produce an empty projection":
    let c = initEmotive()
    let j = emotiveToProviderSettings(c)
    check j.len == 0

  test "caller-set base wins over emotive projection":
    var c = initEmotive()
    c.voiceStability = some(0.4)
    let base = %*{"stability": 0.9}
    let j = emotiveToProviderSettings(c, base)
    check j["stability"].getFloat == 0.9

suite "ElevenLabs capabilities":

  test "self-describes as text-only TTS with voice tuning":
    check ElevenLabsCapabilities.supportsTextInput
    check ElevenLabsCapabilities.supportsVoiceTuning
    check not ElevenLabsCapabilities.supportsAudioInput
    check not ElevenLabsCapabilities.supportsEmotion
    check not ElevenLabsCapabilities.supportsGreenScreen
