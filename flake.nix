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
      };
      p2n = poetry2nix.lib.mkPoetry2Nix {inherit pkgs;};
      outDir = "$out/${pkgs.python311Packages.python.sitePackages}";
      runScript = pkgs.writeShellScriptBin "run.sh" ''
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
            self.packages.${system}.leco
            runScript
            pkgs.dockerTools.caCertificates
          ];
          pathsToLink = ["/bin" "/etc"];
        };
        runAsRoot = ''
          mkdir -p /config
          mkdir -p /data
        '';
        config = {
          WorkingDir = "/data";
          Cmd = ["${pkgs.bash}/bin/bash" "${runScript}/bin/run.sh"];
        };
      };
      containerWithModels = {
        name,
        models,
      }:
        pkgs.dockerTools.buildImage {
          name = "LECO-${name}";
          tag = self.packages.${system}.leco.version;
          created = "now";
          copyToRoot = pkgs.buildEnv {
            name = "image-root";
            paths =
              [
                pkgs.bash
                self.packages.${system}.leco
                runScript
                pkgs.dockerTools.caCertificates
              ]
              ++ models;
            pathsToLink = ["/bin" "/etc" "/models"];
          };
          runAsRoot = ''
            mkdir -p /config
            mkdir -p /data
          '';
          config = {
            WorkingDir = "/data";
            Cmd = ["${pkgs.bash}/bin/bash" "${runScript}/bin/run.sh"];
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
      sdxlContainer = containerWithModels {
        name = "sdxl";
        models = [sdxlModel];
      };
      sd15Container = containerWithModels {
        name = "sd-1-5";
        models = [sd15Model];
      };
      streamedSdxlContainer = pkgs.dockerTools.streamLayeredImage {
        name = "LECO-sdxl";
        tag = self.packages.${system}.leco.version;
        fromImage = sdxlContainer;
      };
      streamedSd15Container = pkgs.dockerTools.streamLayeredImage {
        name = "LECO-sd-1-5";
        tag = self.packages.${system}.leco.version;
        fromImage = sd15Container;
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
                        (pkgs.libtorch-bin.override
                          {cudaSupport = true;})
                        prev.setuptools
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
              prodigyopt =
                prev.prodigyopt.overridePythonAttrs
                (
                  old: {
                    buildInputs =
                      (old.buildInputs or [])
                      ++ [
                        prev.setuptools
                      ];
                  }
                );
              diffusers =
                prev.diffusers.overridePythonAttrs
                (
                  old: {
                    buildInputs =
                      (old.buildInputs or [])
                      ++ [
                        prev.setuptools
                      ];
                  }
                );
              lion-pytorch =
                prev.lion-pytorch.overridePythonAttrs
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
                  buildInputs = (old.buildInputs or []) ++ [pkgs.cudaPackages_12_1.libcusparse];
                }
              );
              nvidia-cusolver-cu12 = prev.nvidia-cusolver-cu12.overrideAttrs (
                old: {
                  buildInputs =
                    (old.buildInputs or [])
                    ++ [
                      pkgs.cudaPackages_12_1.libcusparse
                      pkgs.cudaPackages_12_1.libcublas
                    ];
                }
              );
            })
            p2n.defaultPoetryOverrides
            (final: prev: {
              pytorch-lightning = prev.pytorch-lightning.override {
                preferWheel = true;
                unpackPhase = "";
              };
            })
          ];
        };
        default = self.packages.${system}.leco;
        container = container;
        sdxlContainer = sdxlContainer;
        sd15Container = sd15Container;
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
