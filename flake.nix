{
  description = "The purely functional package manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11-small";
    nixpkgs-regression.url = "github:NixOS/nixpkgs/215d4d0fd80ca5163643b03a33fde804a29cc1e2";
    pre-commit-hooks = {
      url = "github:cachix/git-hooks.nix";
      flake = false;
    };
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-regression,
      pre-commit-hooks,
      flake-compat,
    }:

    let
      inherit (nixpkgs) lib;

      # This notice gets echoed as a dev shell hook, and can be turned off with
      # `touch .nocontribmsg`
      sgr = ''['';
      freezePage = "https://wiki.lix.systems/books/lix-contributors/page/freezes-and-recommended-contributions";
      codebaseOverview = "https://wiki.lix.systems/books/lix-contributors/page/codebase-overview";
      contribNotice = builtins.toFile "lix-contrib-notice" ''
        Hey there!

        If you're thinking of working on Lix, please consider talking to us about it!
        You should be aware that we are ${sgr}1mnot${sgr}0m accepting major features without some conditions,
        and we highly recommend looking at our freeze status page on the wiki:
          ${sgr}32m${freezePage}${sgr}0m

        We also have an overview of the codebase at
          ${sgr}32m${codebaseOverview}${sgr}0m,
        and other helpful information on the wiki.

        But above all else, ${sgr}1mwe want to hear from you!${sgr}0m
        We can help you figure out where in the codebase to look for whatever you want to do,
        and we'd like to work together with all contributors as much as possible.
        Lix is a collaborative project :)

        You can open an issue at https://git.lix.systems/lix-project/lix/issues
        or chat with us on Matrix: #space:lix.systems.

        (Run `touch .nocontribmsg` to hide this message.)
      '';

      officialRelease = false;

      # Set to true to build the release notes for the next release.
      buildUnreleasedNotes = false;

      version = lib.fileContents ./.version + versionSuffix;
      versionSuffix =
        if officialRelease then
          ""
        else
          "pre${
            builtins.substring 0 8 (self.lastModifiedDate or self.lastModified or "19700101")
          }_${self.shortRev or "dirty"}";

      linux32BitSystems = [ "i686-linux" ];
      linux64BitSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      linuxSystems = linux32BitSystems ++ linux64BitSystems;
      darwinSystems = [
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      systems = linuxSystems ++ darwinSystems;

      crossSystems = [
        "armv6l-linux"
        "armv7l-linux"
        # FIXME: doesn't evaluate, plausibly fixed in >=24.05, so recheck when
        # we update to 24.05
        # "x86_64-freebsd13"
        "x86_64-netbsd"
      ];

      stdenvs = [
        "gccStdenv"
        "clangStdenv"
        "stdenv"
        "libcxxStdenv"
        "ccacheStdenv"
      ];

      forAllSystems = lib.genAttrs systems;
      # Same as forAllSystems, but removes nulls, in case something is broken
      # on that system.
      forAvailableSystems =
        f: lib.filterAttrs (name: value: value != null && value != { }) (forAllSystems f);

      forAllCrossSystems = lib.genAttrs crossSystems;

      forAllStdenvs =
        f:
        lib.listToAttrs (
          map (stdenvName: {
            name = "${stdenvName}Packages";
            value = f stdenvName;
          }) stdenvs
        );

      # Memoize nixpkgs for different platforms for efficiency.
      nixpkgsFor = forAllSystems (
        system:
        let
          make-pkgs =
            crossSystem: stdenv:
            import nixpkgs {
              localSystem = {
                inherit system;
              };
              crossSystem =
                if crossSystem == null then
                  null
                else
                  {
                    system = crossSystem;
                  }
                  // lib.optionalAttrs (crossSystem == "x86_64-freebsd13") { useLLVM = true; };
              overlays = [
                (overlayFor (p: p.${stdenv}))
                (final: prev: { nixfmt = final.callPackage ./nix-support/nixfmt.nix { }; })
              ];

              config.permittedInsecurePackages = [ "nix-2.13.6" ];
            };
          stdenvs = forAllStdenvs (make-pkgs null);
          native = stdenvs.stdenvPackages;
        in
        {
          inherit stdenvs native;
          static = native.pkgsStatic;
          cross = forAllCrossSystems (crossSystem: make-pkgs crossSystem "stdenv");
        }
      );

      binaryTarball =
        nix: pkgs: pkgs.callPackage ./nix-support/binary-tarball.nix { inherit nix version; };

      overlayFor =
        getStdenv: final: prev:
        let
          currentStdenv = getStdenv final;
        in
        {
          nixStable = prev.nix;

          # Forward from the previous stage as we don’t want it to pick the lowdown override
          nixUnstable = prev.nixUnstable;

          check-headers = final.buildPackages.callPackage ./maintainers/check-headers.nix { };
          clangbuildanalyzer = final.buildPackages.callPackage ./misc/clangbuildanalyzer.nix { };

          default-busybox-sandbox-shell = final.busybox.override {
            useMusl = true;
            enableStatic = true;
            enableMinimal = true;
            extraConfig = ''
              CONFIG_FEATURE_FANCY_ECHO y
              CONFIG_FEATURE_SH_MATH y
              CONFIG_FEATURE_SH_MATH_64 y

              CONFIG_ASH y
              CONFIG_ASH_OPTIMIZE_FOR_SIZE y

              CONFIG_ASH_ALIAS y
              CONFIG_ASH_BASH_COMPAT y
              CONFIG_ASH_CMDCMD y
              CONFIG_ASH_ECHO y
              CONFIG_ASH_GETOPTS y
              CONFIG_ASH_INTERNAL_GLOB y
              CONFIG_ASH_JOB_CONTROL y
              CONFIG_ASH_PRINTF y
              CONFIG_ASH_TEST y
            '';
          };

          nix = final.callPackage ./package.nix {
            inherit versionSuffix;
            stdenv = currentStdenv;
            busybox-sandbox-shell = final.busybox-sandbox-shell or final.default-busybox-sandbox-shell;
          };

          # Export the patched version of boehmgc that Lix uses into the overlay
          # for consumers of this flake.
          boehmgc-nix = final.nix.boehmgc-nix;
          # And same thing for our build-release-notes package.
          build-release-notes = final.nix.build-release-notes;
        };
    in
    {
      # A Nixpkgs overlay that overrides the 'nix' and
      # 'nix.perl-bindings' packages.
      overlays.default = overlayFor (p: p.stdenv);

      hydraJobs = {

        # Binary package for various platforms.
        build = forAllSystems (system: self.packages.${system}.nix);

        rl-next = forAllSystems (
          system:
          let
            rl-next-check =
              name: dir:
              let
                pkgs = nixpkgsFor.${system}.native;
              in
              pkgs.buildPackages.runCommand "test-${name}-release-notes" { } ''
                LANG=C.UTF-8 ${lib.getExe pkgs.build-release-notes} ${dir} >$out
              '';
          in
          {
            user = rl-next-check "rl-next" ./doc/manual/rl-next;
            dev = rl-next-check "rl-next-dev" ./doc/manual/rl-next-dev;
          }
        );

        # Perl bindings for various platforms.
        perlBindings = forAllSystems (system: nixpkgsFor.${system}.native.nix.perl-bindings);

        # Binary tarball for various platforms, containing a Nix store
        # with the closure of 'nix' package.
        binaryTarball = forAllSystems (
          system: binaryTarball nixpkgsFor.${system}.native.nix nixpkgsFor.${system}.native
        );

        # docker image with Nix inside
        dockerImage = lib.genAttrs linux64BitSystems (system: self.packages.${system}.dockerImage);

        # API docs for Nix's unstable internal C++ interfaces.
        internal-api-docs =
          let
            nixpkgs = nixpkgsFor.x86_64-linux.native;
            inherit (nixpkgs) pkgs;

            nix = pkgs.callPackage ./package.nix {
              inherit versionSuffix officialRelease buildUnreleasedNotes;
              inherit (pkgs) build-release-notes;
              internalApiDocs = true;
              busybox-sandbox-shell = pkgs.busybox-sandbox-shell;
            };
          in
          nix.overrideAttrs (prev: {
            # This Hydra job is just for the internal API docs.
            # We don't need the build artifacts here.
            dontBuild = true;
            doCheck = false;
            doInstallCheck = false;
          });

        # System tests.
        tests = import ./tests/nixos { inherit lib nixpkgs nixpkgsFor; } // {

          # Make sure that nix-env still produces the exact same result
          # on a particular version of Nixpkgs.
          evalNixpkgs =
            with nixpkgsFor.x86_64-linux.native;
            runCommand "eval-nixos" { buildInputs = [ nix ]; } ''
              type -p nix-env
              # Note: we're filtering out nixos-install-tools because https://github.com/NixOS/nixpkgs/pull/153594#issuecomment-1020530593.
              time nix-env --store dummy:// -f ${nixpkgs-regression} -qaP --drv-path | sort | grep -v nixos-install-tools > packages
              [[ $(sha1sum < packages | cut -c1-40) = 402242fca90874112b34718b8199d844e8b03d12 ]]
              mkdir $out
            '';

          nixpkgsLibTests = forAllSystems (
            system:
            import (nixpkgs + "/lib/tests/release.nix") {
              pkgs = nixpkgsFor.${system}.native;
              nixVersions = [ self.packages.${system}.nix ];
            }
          );
        };

        pre-commit = forAvailableSystems (
          system:
          let
            pkgs = nixpkgsFor.${system}.native;
            pre-commit-check = import ./misc/pre-commit.nix { inherit self pkgs pre-commit-hooks; };
            # dotnet-sdk_6, a nativeBuildInputs of pre-commit, is broken on i686-linux.
            available = lib.meta.availableOn { inherit system; } pkgs.dotnet-sdk_6;
          in
          lib.optionalAttrs available pre-commit-check
        );
      };

      # NOTE *do not* add fresh derivations to checks, always add them to
      # hydraJobs first (so CI will pick them up) and only link them here
      checks = forAvailableSystems (
        system:
        {
          binaryTarball = self.hydraJobs.binaryTarball.${system};
          perlBindings = self.hydraJobs.perlBindings.${system};
          nixpkgsLibTests = self.hydraJobs.tests.nixpkgsLibTests.${system};
          rl-next = self.hydraJobs.rl-next.${system}.user;
          rl-next-dev = self.hydraJobs.rl-next.${system}.dev;
          # Will be empty attr set on i686-linux, and filtered out by forAvailableSystems.
          pre-commit = self.hydraJobs.pre-commit.${system};
        }
        // (lib.optionalAttrs (builtins.elem system linux64BitSystems)) {
          dockerImage = self.hydraJobs.dockerImage.${system};
        }
      );

      packages = forAllSystems (
        system:
        rec {
          inherit (nixpkgsFor.${system}.native) nix;
          default = nix;
        }
        // (
          lib.optionalAttrs (builtins.elem system linux64BitSystems) {
            nix-static = nixpkgsFor.${system}.static.nix;
            dockerImage =
              let
                pkgs = nixpkgsFor.${system}.native;
                image = import ./docker.nix {
                  inherit pkgs;
                  tag = version;
                };
              in
              pkgs.runCommand "docker-image-tarball-${version}"
                { meta.description = "Docker image with Nix for ${system}"; }
                ''
                  mkdir -p $out/nix-support
                  image=$out/image.tar.gz
                  ln -s ${image} $image
                  echo "file binary-dist $image" >> $out/nix-support/hydra-build-products
                '';
          }
          // builtins.listToAttrs (
            map (crossSystem: {
              name = "nix-${crossSystem}";
              value = nixpkgsFor.${system}.cross.${crossSystem}.nix;
            }) crossSystems
          )
          // builtins.listToAttrs (
            map (stdenvName: {
              name = "nix-${stdenvName}";
              value = nixpkgsFor.${system}.stdenvs."${stdenvName}Packages".nix;
            }) stdenvs
          )
        )
      );

      devShells =
        let
          makeShell =
            pkgs: stdenv:
            let
              nix = pkgs.callPackage ./package.nix {
                inherit stdenv versionSuffix;
                busybox-sandbox-shell = pkgs.busybox-sandbox-shell or pkgs.default-busybox-sandbox;
                internalApiDocs = true;
              };
              pre-commit = self.hydraJobs.pre-commit.${pkgs.system} or { };
            in
            pkgs.callPackage nix.mkDevShell {
              pre-commit-checks = pre-commit;
              inherit contribNotice;
            };
        in
        forAllSystems (
          system:
          let
            makeShells =
              prefix: pkgs:
              lib.mapAttrs' (k: v: lib.nameValuePair "${prefix}-${k}" v) (
                forAllStdenvs (stdenvName: makeShell pkgs pkgs.${stdenvName})
              );
          in
          (makeShells "native" nixpkgsFor.${system}.native)
          // (makeShells "static" nixpkgsFor.${system}.static)
          // (forAllCrossSystems (
            crossSystem:
            let
              pkgs = nixpkgsFor.${system}.cross.${crossSystem};
            in
            makeShell pkgs pkgs.stdenv
          ))
          // {
            default = self.devShells.${system}.native-stdenvPackages;
          }
        );
    };
}
