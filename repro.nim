## Complete existing three-module corpus; live commercial API acceptance
## remains the unchanged separate mandatory just test-live gate.
import repro_project_dsl
import repro_dsl_stdlib/foreign_env
import ct_test_nim_unittest
import elevenlabs_multimedia_tools

package projectEnvironment:
  devEnv:
    useFlakeDevShell()
  defaultToolProvisioning "path"
  uses:
    "nim >=2.0 <3.0"
    when defined(macosx):
      "clang >=15"
    else:
      "gcc >=12"
    "elevenlabs_ffmpeg"
    "elevenlabs_ffprobe"
  build:
    let inputs = @["src", "tests", "config.nims", "gui_assert_elevenlabs.nimble",
      "flake.lock", "elevenlabs_multimedia_tools.nim", "../GuiAssert/src"]
    let backend = when defined(macosx): @["clang"] else: @["gcc"]
    var builds, executes: seq[BuildActionDef] = @[]
    for stem in ["tnimcache_is_worktree_local", "televenlabs", "temotive_translation"]:
      let edge = buildNimUnittest.build(source = "tests/" & stem & ".nim",
        binary = "build/test-bin/" & stem,
        paths = @["src", "../GuiAssert/src"],
        threadsOn = stem != "tnimcache_is_worktree_local",
        hintsOff = true, warningsOff = false,
        actionId = "elevenlabs.test_build." & stem, extraInputs = inputs)
      appendRegisteredActionToolIdentityRefs(edge.action.id, backend)
      builds.add(edge.action)
      let execution = edge.testBinary.run(
        actionId = "elevenlabs.test_execute." & stem,
        extraInputs = inputs, registerImplicitName = false)
      if stem == "tnimcache_is_worktree_local":
        appendRegisteredActionToolIdentityRefs(execution.id, @["nim"])
      elif stem == "televenlabs":
        appendRegisteredActionToolIdentityRefs(execution.id, @["elevenlabs_ffmpeg", "elevenlabs_ffprobe"])
      executes.add(execution)
    discard collect("test-builds", builds)
    discard collect("test", executes)
