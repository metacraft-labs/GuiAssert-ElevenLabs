# Test fixtures

## `narration.wav` — short test narration

A ~3.5 second WAV (16 kHz mono PCM) of the phrase
"Hello from GuiAssert ElevenLabs. This is a test render.", generated
via macOS `say` and resampled with `ffmpeg`:

```
say -o tmp.aiff "Hello from GuiAssert ElevenLabs. This is a test render."
ffmpeg -i tmp.aiff -ar 16000 -ac 1 narration.wav
```

This WAV is **not** consumed by the ElevenLabs provider — ElevenLabs
synthesises its own audio from the per-call `text` string.  The
fixture is reserved for cache-key sanity checks and parity with the
sibling talking-head plugin fixtures; the live ElevenLabs test
neither uploads it nor reads it.
