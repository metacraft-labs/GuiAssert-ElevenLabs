# GuiAssert-ElevenLabs
#
# `just test`              - run the pure + mock-server tests (no network).
# `just test-live`         - run the gated live test (-d:elevenlabsLive). Requires ELEVENLABS_API_KEY.
# `just lint`              - check the owning source and all three test modules.

default: test

# Pure unit tests + mock-server integration test for the plugin.
# Compiles against the sibling GuiAssert checkout via
# --path:../GuiAssert/src.  `--threads:on` is required by the
# mock-server test: it spawns a thread that drives the asyncdispatch
# loop so the main thread can block in httpclient calls.
test:
    nim c -r --hints:off --path:src tests/tnimcache_is_worktree_local.nim
    nim c -r --threads:on --hints:off --path:src --path:../GuiAssert/src tests/televenlabs.nim
    nim c -r --threads:on --hints:off --path:src --path:../GuiAssert/src tests/temotive_translation.nim

# End-to-end live test against the real ElevenLabs API.  Requires
# ELEVENLABS_API_KEY to be set in the environment; the test compiles
# but fails loudly if it is missing (no graceful skips per project
# policy).
test-live:
    nim c -d:elevenlabsLive -r --threads:on --hints:off --path:src --path:../GuiAssert/src tests/televenlabs.nim

# Check the real complete source/corpus rather than returning placeholder success.
lint:
    nim check --hints:off --path:src tests/tnimcache_is_worktree_local.nim
    nim check --threads:on --hints:off --path:src --path:../GuiAssert/src src/gui_assert_elevenlabs.nim
    nim check --threads:on --hints:off --path:src --path:../GuiAssert/src tests/televenlabs.nim
    nim check --threads:on --hints:off --path:src --path:../GuiAssert/src tests/temotive_translation.nim
