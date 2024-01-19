{
  description = "Application packaged using poetry2nix";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    poetry2nix = {
      url = "github:Pegasust/poetry2nix/orjson";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    poetry2nix,
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        config.cudaSupport = true;
        config.cudaCapabilities = ["7.0" "8.0" "8.6"];
      };
      p2n = poetry2nix.lib.mkPoetry2Nix {inherit pkgs;};
      outDir = "$out/${pkgs.python311Packages.python.sitePackages}";
      runScript = pkgs.writeShellScriptBin "run.sh" ''
        mkdir -p /config /data

        /bin/nvidia-smi

        if [ -n "$LECO_CONFIG" ]; then
          echo "$LECO_CONFIG" > /config/config.yaml
        fi
        if [ -n "$LECO_PROMPT" ]; then
          echo "$LECO_PROMPT" > /config/prompt.yaml
        fi
        ${self.packages.${system}.leco}/bin/train_lora_xl --config_file /config/config.yaml
      '';
      container = pkgs.dockerTools.buildImage {
        name = "LECO";
        tag = self.packages.${system}.leco.version;
        created = "now";
        copyToRoot = pkgs.buildEnv {
          name = "image-root";
          paths = [
            pkgs.bash
            pkgs.uutils-coreutils-noprefix
            self.packages.${system}.leco
            runScript
            pkgs.dockerTools.caCertificates
            pkgs.cudaPackages_12.cudatoolkit
          ];
          pathsToLink = ["/bin" "/etc"];
        };
        runAsRoot = ''
          mkdir -p /config
          mkdir -p /data
        '';
        config = {
          Cmd = ["${pkgs.bash}/bin/bash" "${runScript}/bin/run.sh"];
          Env = [
            "NVIDIA_DRIVER_CAPABILITIES=compute,utility"
            "NVIDIA_VISIBLE_DEVICES=all"
            "LD_LIBRARY_PATH=/usr/lib64"
          ];
          WorkingDir = "/data";
        };
      };
      streamedContainerWithModels = {
        name,
        models,
      }:
        pkgs.dockerTools.streamLayeredImage {
          name = "LECO-${name}";
          tag = self.packages.${system}.leco.version;
          created = "now";
          contents = pkgs.buildEnv {
            name = "image-root";
            paths =
              [
                pkgs.bash
                pkgs.uutils-coreutils-noprefix
                self.packages.${system}.leco
                runScript
                pkgs.dockerTools.caCertificates
                pkgs.cudaPackages_12.cudatoolkit
                (pkgs.stdenv.mkDerivation
                  {
                    name = "mkdirConfigData";
                    src = ./.;
                    phases = ["installPhase"];
                    installPhase = ''
                      mkdir -p $out/config
                      mkdir -p $out/data
                    '';
                  })
              ]
              ++ models;
            pathsToLink = ["/bin" "/etc" "/models" "/config" "/data"];
          };
          config = {
            Cmd = ["${pkgs.bash}/bin/bash" "${runScript}/bin/run.sh"];
            Env = [
              "NVIDIA_DRIVER_CAPABILITIES=compute,utility"
              "NVIDIA_VISIBLE_DEVICES=all"
              "LD_LIBRARY_PATH=/usr/lib64"
            ];
            WorkingDir = "/data";
          };
        };
      downloadModel = {
        filename,
        url,
        hash,
      }:
        pkgs.fetchurl {
          url = url;
          hash = hash;
          curlOpts = "-L";
          downloadToTemp = true;
          recursiveHash = true;
          postFetch = ''
            mkdir -p $out/models
            mv $downloadedFile $out/models/${filename}
          '';
        };
      sdxlModel = downloadModel {
        filename = "sd_xl_base_1.0.safetensors";
        url = "https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors";
        hash = "sha256-5A9qgIbo33PU3tuRLg829Ty++WSPZ1D4+gpWOML2pFk=";
      };
      sd15Model = downloadModel {
        filename = "v1-5-pruned-emaonly.safetensors";
        url = "https://huggingface.co/runwayml/stable-diffusion-v1-5/resolve/main/v1-5-pruned-emaonly.safetensors";
        hash = "sha256-0H+/b+joVlsQm9YIjJWDUFNq+50M9rrA4LsTN4dI1k4=";
      };
      streamedSdxlContainer = streamedContainerWithModels {
        name = "sdxl";
        models = [sdxlModel];
      };
      streamedSd15Container = streamedContainerWithModels {
        name = "sd-1-5";
        models = [sd15Model];
      };
    in {
      packages = {
        leco = p2n.mkPoetryApplication {
          projectDir = self;
          src = p2n.cleanPythonSources {src = self;};
          pyproject = ./pyproject.toml;
          poetrylock = ./poetry.lock;
          preferWheels = true;
          python = pkgs.python311;
          overrides = [
            (final: prev: {
              xformers =
                prev.xformers.overridePythonAttrs
                (
                  old: {
                    buildInputs =
                      (old.nativeBuildInputs or [])
                      ++ [
                        pkgs.libtorch-bin
                        pkgs.cudaPackages_12.cuda_cudart
                      ];
                  }
                );
              dadaptation =
                prev.dadaptation.overridePythonAttrs
                (
                  old: {
                    buildInputs =
                      (old.buildInputs or [])
                      ++ [
                        prev.setuptools
                      ];
                  }
                );
              nvidia-cusparse-cu12 = prev.nvidia-cusparse-cu12.overrideAttrs (
                old: {
                  buildInputs = (old.buildInputs or []) ++ [pkgs.cudaPackages_12.libnvjitlink];
                }
              );
              nvidia-cusolver-cu12 = prev.nvidia-cusolver-cu12.overrideAttrs (
                old: {
                  buildInputs =
                    (old.buildInputs or [])
                    ++ [
                      pkgs.cudaPackages_12.libcusparse
                      pkgs.cudaPackages_12.libcublas
                    ];
                }
              );
            })
            p2n.defaultPoetryOverrides
          ];
        };
        default = self.packages.${system}.leco;
        container = container;
        streamedSdxlContainer = streamedSdxlContainer;
        streamedSd15Container = streamedSd15Container;
      };

      apps = {
        leco = {
          type = "app";
          program = "${pkgs.buildFHSUserEnv {
            name = "leco-fhs";
            targetPkgs = pkgs: (with pkgs; [
              cudatoolkit
              cudaPackages_12_1.cudnn
            ]);
            runScript = "${pkgs.writeShellScriptBin "run.sh" ''
              ${self.packages.${system}.leco}/bin/run $@
            ''}/bin/run.sh";
          }}/bin/leco-fhs";
        };
        default = self.apps.${system}.leco;
      };

      devShells.default = pkgs.mkShell {
        packages = [pkgs.poetry];
      };
    });
}
