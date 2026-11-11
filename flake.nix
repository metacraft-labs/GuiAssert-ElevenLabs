{
  description = "GuiAssert-ElevenLabs - ElevenLabs TTS plugin for GuiAssert";

  inputs = {
    standard-hooks-src = {
      url = "github:metacraft-labs/devops-modules/f1b80ff31d6ca681b67c83d36fc29e6c8e23a7a6";
      flake = false;
    };
    nixos-modules.url = "github:metacraft-labs/devops-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      git-hooks,
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
        let
          ownRepoOnly = script: ''
            _own_repo_root="$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || true)"
            if [ -n "$_own_repo_root" ] && [ -f "$_own_repo_root/flake.nix" ] \
              && [ "$(${pkgs.coreutils}/bin/sha256sum "$_own_repo_root/flake.nix" | ${pkgs.coreutils}/bin/cut -d' ' -f1)" \
                = "${builtins.hashFile "sha256" ./flake.nix}" ]; then
            ${script}
            # git-hooks.nix's installer leaves core.hooksPath as the RELATIVE
            # `.git/hooks`, in the config every worktree shares. A linked worktree
            # cannot resolve it (there `.git` is a file), so git silently runs no
            # hooks there. Point it at the common hooks directory instead.
            if [ "$(${pkgs.git}/bin/git config --local --get core.hooksPath 2>/dev/null)" = .git/hooks ]; then
              ${pkgs.git}/bin/git config --local core.hooksPath "$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-common-dir)/hooks"
            fi
            fi
            unset _own_repo_root
          '';

          # The shared explicit installer (devops-modules lib/git-hooks-explicit-install.nix)
          # runs the same-repository guard, the native installer and the Reprobuild
          # handoff, and exports REPROBUILD_REPRO to the matching repro CLI.
          explicitHookInstaller = import (inputs.standard-hooks-src + "/lib/git-hooks-explicit-install.nix") {
            inherit pkgs preCommit;
            expectedFlakeNixHash = builtins.hashFile "sha256" ./flake.nix;
          };

          standardHooks = import (inputs.standard-hooks-src + "/git-hooks/standard-hooks.nix") {
            inherit pkgs;
            lib = pkgs.lib;
            src = inputs.standard-hooks-src;
          };
          preCommit = git-hooks.lib.${system}.run {
            src = ./.;
            hooks = standardHooks // {
              lint = {
                enable = true;
                name = "just lint";
                entry = "just lint";
                extraPackages = with pkgs; [
                  bash
                  coreutils
                  just
                  nim
                ];
                language = "system";
                pass_filenames = false;
              };
            };
          };
        in
        {
          checks.pre-commit = preCommit;
          devShells.default = pkgs.mkShell {
            # ElevenLabs is a commercial HTTP API, so this plugin has
            # no Python / no model weights / no GPU toolchain — just a
            # pure-Nim HTTP client plus ffmpeg to convert the returned
            # MP3 into the WAV shape GuiAssert's pipeline expects.
            packages =
              with pkgs;
              [
                nim
                nimble
                just
                git
                curl
                ffmpeg-full
                openssl
                cacert
                pre-commit
                python3
              ]
              ++ preCommit.enabledPackages;
            shellHook = ''
              ${ownRepoOnly ''
                ${explicitHookInstaller}/bin/mcl-install-own-hooks || exit 1
              ''}
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
              echo "  just test-live   # paid on-demand TTS render (requires explicit request and ELEVENLABS_API_KEY)"
            '';
          };
        };
    };
}
