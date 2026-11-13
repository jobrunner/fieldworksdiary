{
  description = "fieldworksdiary-ng — Dev-Shell für Backend (Go/PocketBase) und iOS (SwiftUI)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        isDarwin = pkgs.stdenv.isDarwin;

        # Tools, die auf allen Plattformen verfügbar sind.
        # backend/go.mod verlangt go 1.27.4. Liegt in nixpkgs nur eine
        # ältere Patch-Version, lädt Go die passende Toolchain selbst nach
        # (GOTOOLCHAIN=auto).
        commonTools = with pkgs; [
          go_1_27
          golangci-lint
          govulncheck
          gofumpt
          gotools          # goimports, godoc
          delve            # Go-Debugger
          gitleaks         # Secrets-Scan
          trivy            # Filesystem- und Container-Vuln-Scan
          cyclonedx-gomod  # SBOM-Generator (CycloneDX-Format)
          go-licenses      # License-Compliance-Check
          semgrep          # Multi-Sprach-SAST (Go + Swift Rulesets)
          zizmor           # GitHub-Actions-Workflows-Audit
          jq
          coreutils
          git
        ];

        # Swift-Tooling — nur auf macOS sinnvoll (iOS-Build braucht eh Darwin).
        # Dieselben Versionen nutzt die CI (ios.yml, Shell `ios-lint`).
        iosLintTools = with pkgs; [
          swiftlint
          swiftformat
          xcodegen
          periphery
        ];
        darwinTools = pkgs.lib.optionals isDarwin (iosLintTools ++ [
          pkgs.xcodes      # Helper zum Installieren konkreter Xcode-Versionen
        ]);

        # Nix setzt DEVELOPER_DIR auf einen Stub-SDK ohne `swift` —
        # SourceKitten (SwiftLint) crasht damit. Außerdem führt das dazu,
        # dass `xcode-select -p` ebenfalls Nix's Stub zurückgibt
        # (xcode-select bevorzugt DEVELOPER_DIR). Deshalb fragen wir
        # xcode-select ohne DEVELOPER_DIR; zeigt es auf ein Xcode (in der CI
        # per `xcode-select -s` gewählt), gilt das, sonst die üblichen Pfade.
        # Nix prepended außerdem sein eigenes xcrun-Stub (aus xcbuild);
        # SwiftLint braucht aber Apples xcrun aus /usr/bin.
        xcodeHook = ''
          _xcode="$(env -u DEVELOPER_DIR /usr/bin/xcode-select -p 2>/dev/null || true)"
          case "$_xcode" in
            *.app/Contents/Developer) export DEVELOPER_DIR="$_xcode" ;;
            *)
              if [ -d /Applications/Xcode.app/Contents/Developer ]; then
                export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
              elif [ -d /Library/Developer/CommandLineTools ]; then
                export DEVELOPER_DIR=/Library/Developer/CommandLineTools
              fi
              ;;
          esac
          unset _xcode
          export PATH="/usr/bin:$PATH"
        '';
      in
      {
        # Schlanke Shell nur für den iOS-Lint (CI und lokal). mkShellNoCC
        # zieht weder Compiler noch Nix-apple-sdk, dadurch bleibt der
        # Download in der CI klein.
        devShells.ios-lint = pkgs.mkShellNoCC {
          name = "fieldworksdiary-ios-lint";
          packages = iosLintTools;
          shellHook = xcodeHook;
        };

        devShells.default = pkgs.mkShell {
          name = "fieldworksdiary-ng";

          packages = commonTools ++ darwinTools;

          shellHook = ''
            ${pkgs.lib.optionalString isDarwin xcodeHook}

            # mkShell propagiert auf Darwin ein Nix-eigenes apple-sdk (z.B.
            # apple-sdk-14.4) und setzt SDKROOT dorthin. Dieses SDK ist
            # unvollständig (u.a. fehlt libresolv), wodurch `go build` von
            # cgo-Code mit `ld: library 'resolv' not found` abbricht. Wir
            # zwingen SDKROOT auf das CLT-SDK, wenn xcrun verfügbar ist.
            if command -v /usr/bin/xcrun >/dev/null 2>&1; then
              _system_sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
              if [ -n "$_system_sdk" ]; then
                export SDKROOT="$_system_sdk"
              fi
              unset _system_sdk
            fi

            echo "fieldworksdiary-ng dev-shell"
            echo "  go:             $(go version 2>/dev/null | awk '{print $3}')"
            echo "  golangci-lint:  $(golangci-lint --version 2>/dev/null | head -1 | awk '{print $4}')"
            echo "  govulncheck:    $(govulncheck -version 2>/dev/null | head -1 || echo 'n/a')"
            ${pkgs.lib.optionalString isDarwin ''
              echo "  swiftlint:      $(swiftlint version 2>/dev/null)"
              echo "  swiftformat:    $(swiftformat --version 2>/dev/null)"
              if ! xcode-select -p >/dev/null 2>&1; then
                echo ""
                echo "  ! Xcode CLT nicht gefunden — 'xcode-select --install' ausführen."
              fi
            ''}
            echo ""
            echo "  full QA:        bash scripts/check.sh"
          '';
        };
      });
}
