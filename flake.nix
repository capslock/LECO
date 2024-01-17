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
        ${self.packages.${system}.leco}/bin/train_lora_xl
      '';
      container = {
        name = self.packages.${system}.leco.name;
        tag = self.packages.${system}.leco.version;
        created = "now";
        copyToRoot = pkgs.buildEnv {
          name = "image-root";
          pathsToLink = ["/bin"];
          paths = [pkgs.bash self.packages.${system}.leco runScript];
        };
        config = {
          Cmd = ["${pkgs.bash}/bin/bash" "${runScript}/bin/run.sh"];
        };
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
        container = pkgs.dockerTools.buildImage container;
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
