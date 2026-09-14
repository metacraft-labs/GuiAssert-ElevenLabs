{
  description = "GuiAssert-ElevenLabs - ElevenLabs TTS plugin for GuiAssert";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/devops-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      perSystem =
        { pkgs, system, ... }:
        {
          devShells.default = pkgs.mkShell {
            # ElevenLabs is a commercial HTTP API, so this plugin has
            # no Python / no model weights / no GPU toolchain — just a
            # pure-Nim HTTP client plus ffmpeg to convert the returned
            # MP3 into the WAV shape GuiAssert's pipeline expects.
            packages = with pkgs; [
              nim
              nimble
              just
              git
              curl
              ffmpeg-full
              openssl
              cacert
            ];
            shellHook = ''
              # Make Nim's httpclient pick up the system CA bundle so
              # TLS to api.elevenlabs.io works without user setup.
              export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              echo "GuiAssert-ElevenLabs dev shell ready."
              echo "  nim:      $(nim --version | head -1)"
              echo "  ffmpeg:   $(ffmpeg -version | head -1)"
              echo "  openssl:  $(openssl version)"
              echo
              if [ -z "$ELEVENLABS_API_KEY" ]; then
                echo "NOTE: ELEVENLABS_API_KEY is not set."
                echo "      Pure tests + mock-server tests work without it."
                echo "      The -d:elevenlabsLive test requires it (set via: export ELEVENLABS_API_KEY=...)."
                echo "      ElevenLabs pricing starts at \$5/mo (Starter ~30 min)."
              else
                echo "  ELEVENLABS_API_KEY: set (length=$${#ELEVENLABS_API_KEY})"
              fi
              echo
              echo "Next steps:"
              echo "  just test        # pure + mock-server tests"
              echo "  just test-live   # live TTS render against api.elevenlabs.io (requires ELEVENLABS_API_KEY)"
            '';
          };
        };
    };
}
