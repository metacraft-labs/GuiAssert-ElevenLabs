## Owning FFmpeg/FFprobe CLI identities from the committed flake follows chain.
## Catalog import preserves the project recipe as the sole root package.
import std/json
import repro_project_dsl

const owningLock = staticRead("flake.lock")
proc resolvedInputNode(lock, reference: JsonNode; depth = 0): string =
  doAssert depth <= lock["nodes"].len, "cyclic owning flake input follows"
  if reference.kind == JString:
    result = reference.getStr
    doAssert lock["nodes"].hasKey(result), "missing owning flake input node"
  else:
    doAssert reference.kind == JArray and reference.len > 0
    result = lock["root"].getStr
    for segment in reference:
      result = resolvedInputNode(lock,
        lock["nodes"][result]["inputs"][segment.getStr], depth + 1)
let lockDocument = parseJson(owningLock)
let owningNixpkgs = lockDocument["nodes"][resolvedInputNode(lockDocument,
  lockDocument["nodes"][lockDocument["root"].getStr]["inputs"]["nixpkgs"])]["locked"]
package elevenlabs_ffmpeg:
  provisioning:
    nixPackage "nixpkgs#ffmpeg-full", executablePath = "bin/ffmpeg",
      nixpkgsRev = owningNixpkgs["rev"].getStr,
      nixpkgsNarHash = owningNixpkgs["narHash"].getStr
package elevenlabs_ffprobe:
  provisioning:
    nixPackage "nixpkgs#ffmpeg-full", executablePath = "bin/ffprobe",
      nixpkgsRev = owningNixpkgs["rev"].getStr,
      nixpkgsNarHash = owningNixpkgs["narHash"].getStr
