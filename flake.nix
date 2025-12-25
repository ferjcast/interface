{
  description = "Aave Protocol Interface - Fully Hermetic Nix Build";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = { allowUnfree = true; };
        };

        nodejs = pkgs.nodejs_22;
        yarn = pkgs.yarn.override { inherit nodejs; };

        version = "3.0.1";
        pname = "aave-interface";

        # Fetch yarn dependencies (hermetic)
        # To compute hash: run `nix build`, copy the correct hash from error
        yarnOfflineCache = pkgs.fetchYarnDeps {
          yarnLock = ./yarn.lock;
          hash = "sha256-E1PWOJcaXKWjlIZeItQqcNZhXnnXXwhObc9NdY6Q/Dg=";
        };

        # The main hermetic build
        aaveInterface = pkgs.stdenv.mkDerivation {
          inherit pname version;
          src = ./.;

          nativeBuildInputs = [
            nodejs
            yarn
            pkgs.fixup-yarn-lock
          ];

          configurePhase = ''
            runHook preConfigure
            export HOME=$TMPDIR
            export NEXT_TELEMETRY_DISABLED=1
            export CYPRESS_INSTALL_BINARY=0

            yarn config --offline set yarn-offline-mirror ${yarnOfflineCache}
            fixup-yarn-lock yarn.lock
            yarn install --frozen-lockfile --offline --no-progress --non-interactive
            runHook postConfigure
          '';

          buildPhase = ''
            runHook preBuild
            yarn build
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out
            cp -r .next $out/
            cp -r public $out/ 2>/dev/null || true
            cp -r node_modules $out/
            cp package.json $out/
            cp next.config.js $out/ 2>/dev/null || true

            mkdir -p $out/bin
            cat > $out/bin/aave-interface <<EOF
            #!/bin/sh
            cd $out
            exec ${nodejs}/bin/node node_modules/.bin/next start "\$@"
            EOF
            chmod +x $out/bin/aave-interface
            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Aave Protocol Interface";
            homepage = "https://github.com/aave/interface";
            license = licenses.bsd3;
            mainProgram = "aave-interface";
          };
        };

        dockerImage = pkgs.dockerTools.buildImage {
          name = pname;
          tag = version;
          copyToRoot = pkgs.buildEnv {
            name = "${pname}-root";
            paths = [ aaveInterface nodejs pkgs.cacert ];
            pathsToLink = [ "/bin" "/etc" ];
          };
          config = {
            Entrypoint = [ "${aaveInterface}/bin/aave-interface" ];
            ExposedPorts = { "3000/tcp" = {}; };
            Env = [
              "NODE_ENV=production"
              "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            ];
          };
        };

        testArtifactScript = pkgs.writeShellScriptBin "test-artifact" ''
          set -e
          echo "Testing Aave Interface build artifact"
          echo "========================================"
          ARTIFACT="${aaveInterface}"
          echo "Build directory:"
          ls -la "$ARTIFACT/.next/" | head -20
          echo ""
          echo "Package info:"
          cat "$ARTIFACT/package.json" | ${pkgs.jq}/bin/jq '{name, version}'
          echo ""
          echo "Build size:"
          du -sh "$ARTIFACT/.next/"
          echo ""
          echo "Starting server (5 second test)..."
          timeout 5 "$ARTIFACT/bin/aave-interface" 2>&1 || true
          echo "Artifact tests completed!"
        '';

        generateSbomScript = pkgs.writeShellScriptBin "generate-sbom" ''
          set -e
          echo "Generating SBOM for Aave Interface..."
          OUTDIR="''${1:-.}"
          ARTIFACT="${aaveInterface}"
          ${pkgs.syft}/bin/syft dir:"$ARTIFACT" -o spdx-json="$OUTDIR/aave-interface-sbom.spdx.json"
          ${pkgs.syft}/bin/syft dir:"$ARTIFACT" -o cyclonedx-json="$OUTDIR/aave-interface-sbom.cdx.json"
          echo "SBOMs generated in $OUTDIR"
        '';

        scanVulnsScript = pkgs.writeShellScriptBin "scan-vulns" ''
          set -e
          echo "Scanning Aave Interface for vulnerabilities..."
          ARTIFACT="${aaveInterface}"
          ${pkgs.grype}/bin/grype dir:"$ARTIFACT" 2>&1 | head -100 || true
          echo "Vulnerability scan complete!"
        '';

        verifySignatureScript = pkgs.writeShellScriptBin "verify-signature" ''
          set -e
          echo "Verifying Git commit signature..."
          if [ ! -e ".git" ]; then
            echo "ERROR: Not a git repository! Run this from the project directory."
            exit 1
          fi
          echo "Importing Aave GPG keys..."
          ${pkgs.curl}/bin/curl -sfL https://github.com/aave.gpg | ${pkgs.gnupg}/bin/gpg --import 2>/dev/null || true
          COMMIT=$(${pkgs.git}/bin/git rev-parse HEAD)
          echo "Commit: $COMMIT"
          ${pkgs.git}/bin/git verify-commit HEAD 2>&1 || { echo "Signature verification failed!"; exit 1; }
          echo "Commit signature is VALID!"
        '';

        devServerScript = pkgs.writeShellScriptBin "dev-server" ''
          set -e
          export NEXT_TELEMETRY_DISABLED=1
          if [ ! -d "node_modules" ]; then
            ${yarn}/bin/yarn install --frozen-lockfile
          fi
          ${yarn}/bin/yarn dev
        '';

      in {
        packages = {
          default = aaveInterface;
          inherit aaveInterface dockerImage;
          test-artifact = testArtifactScript;
          generate-sbom = generateSbomScript;
          scan-vulns = scanVulnsScript;
          verify-signature = verifySignatureScript;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            nodejs yarn pkgs.git pkgs.jq pkgs.curl
            pkgs.syft pkgs.grype pkgs.gnupg
            devServerScript
          ];
          shellHook = ''
            echo "Aave Interface Development Shell"
            echo "Node.js: $(node --version)"
            echo ""
            echo "Hermetic: nix build, nix run .#test-artifact"
            echo "Dev: dev-server"
            export NEXT_TELEMETRY_DISABLED=1
          '';
        };

        apps = {
          default = { type = "app"; program = "${aaveInterface}/bin/aave-interface"; };
          test-artifact = { type = "app"; program = "${testArtifactScript}/bin/test-artifact"; };
          generate-sbom = { type = "app"; program = "${generateSbomScript}/bin/generate-sbom"; };
          scan-vulns = { type = "app"; program = "${scanVulnsScript}/bin/scan-vulns"; };
          verify-signature = { type = "app"; program = "${verifySignatureScript}/bin/verify-signature"; };
        };
      }
    );
}
