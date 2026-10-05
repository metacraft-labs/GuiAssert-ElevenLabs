{
  description = "GuiAssert-ElevenLabs - ElevenLabs TTS plugin for GuiAssert";

  inputs = {
    standard-hooks-src = {
      url = "github:metacraft-labs/devops-modules/c8ef41d446e211892fe9775182b43d5d517554ac";
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

          expectedNativeHook =
            pkgs.runCommand "elevenlabs-native-pre-commit-hook"
              {
                nativeBuildInputs = [
                  pkgs.git
                  preCommit.config.package
                ];
              }
              ''
                export PRE_COMMIT_HOME="$TMPDIR/elevenlabs-native-hook-cache"
                mkdir -p "$PRE_COMMIT_HOME" fixture
                cd fixture
                export GIT_CONFIG_GLOBAL="$TMPDIR/elevenlabs-native-factory-gitconfig"
                export GIT_CONFIG_NOSYSTEM=1
                : > "$GIT_CONFIG_GLOBAL"
                git init --template= >/dev/null
                if git config --get core.hooksPath; then
                  echo 'Unexpected native factory hooksPath authority' >&2
                  exit 1
                fi
                test "$(git rev-parse --path-format=absolute --git-path hooks)" = "$PWD/.git/hooks"
                ln -s ${preCommit.config.configFile} ${preCommit.config.configPath}
                mkdir -p "$out"
                for hook in pre-commit pre-push; do
                  ${preCommit.config.package}/bin/pre-commit install -c ${preCommit.config.configPath} -t "$hook"
                  install -m 0755 ".git/hooks/$hook" "$out/$hook"
                done
              '';
          hookOwnershipGuard = ./nix/hook-ownership-guard.py;
          guardedHookInstall = ''
            (
              set -eu
              _own_hook_receipt="$(${pkgs.coreutils}/bin/mktemp)"
              trap '${pkgs.coreutils}/bin/rm -f "$_own_hook_receipt"' EXIT
              ${pkgs.python3}/bin/python3 ${hookOwnershipGuard} "$_own_repo_root" ${expectedNativeHook} prepare reserved ${pkgs.git}/share/git-core/templates > "$_own_hook_receipt"
              _own_matching_repro="$(${pkgs.python3}/bin/python3 ${hookOwnershipGuard} "$_own_repo_root" ${expectedNativeHook} tool reserved ${pkgs.git}/share/git-core/templates)"
              _own_install_needed=1
              if [ -L "$_own_repo_root/${preCommit.config.configPath}" ] \
                && [ "$(${pkgs.coreutils}/bin/readlink "$_own_repo_root/${preCommit.config.configPath}")" = "${preCommit.config.configFile}" ]; then
                _own_install_needed=0
              fi
              ${preCommit.shellHook}
              if [ "$_own_install_needed" -eq 1 ]; then
                ${pkgs.python3}/bin/python3 ${hookOwnershipGuard} "$_own_repo_root" ${expectedNativeHook} native reserved ${pkgs.git}/share/git-core/templates
              fi
              "$_own_matching_repro" hooks ensure --vcs "$_own_repo_root"
              ${pkgs.python3}/bin/python3 ${hookOwnershipGuard} "$_own_repo_root" ${expectedNativeHook} after "$_own_hook_receipt" ${pkgs.git}/share/git-core/templates
            )
            _own_hook_status=$?
            if [ "$_own_hook_status" -ne 0 ]; then
              unset _own_hook_status
              exit 1
            fi
            unset _own_hook_status
          '';

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
              ${ownRepoOnly guardedHookInstall}
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
