{
  inputs = {
    nixpkgs.url = "nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        deps = import ./Cargo.nix { inherit pkgs; };

        libraries = with pkgs; [
          # openssl
          # wayland
          # wayland-protocols
          # libxkbcommon
          # xorg.libxcb

            pkgs.wayland
            pkgs.wayland-protocols
            pkgs.libxkbcommon
            pkgs.xorg.libxcb
            pkgs.openssl
        ];

        packages = with pkgs; [
          # pkg-config
          # openssl
          # wayland
          # wayland-protocols
          # libxkbcommon
          # xorg.libxcb

            pkgs.pkg-config
            pkgs.wayland
            pkgs.wayland-protocols
            pkgs.libxkbcommon
            pkgs.xorg.libxcb
            pkgs.openssl
        ];
      in
      {
        devShell = pkgs.mkShell {
          buildInputs = packages;

          shellHook = ''
            # export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath libraries}:$LD_LIBRARY_PATH
            # export WAYLAND_PROTOCOLS=${pkgs.wayland-protocols}/share/wayland-protocols

            # Set XDG_RUNTIME_DIR if not set (adjust if your compositor uses something else)
            # if [ -z "$XDG_RUNTIME_DIR" ]; then
            #   export XDG_RUNTIME_DIR=/run/user/$(id -u)
            # fi
            #
            # export XDG_DATA_DIRS=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}:$XDG_DATA_DIRS

            # if running from zsh, reenter zsh
            if [[ $(ps -e | grep $PPID) == *"zsh" ]]; then
              export SHELL=zsh
              zsh
              exit
            fi
          '';
        };

        packages = {
           aw-wayland = pkgs.rustPlatform.buildRustPackage {
            pname = "aw-wayland";
            version = "0.1.0";

            src = ./.;  # assumes your Rust project is in the flake root

            cargoLock = {
             lockFile = ./Cargo.lock;
             outputHashes = {
                "aw-client-rust-0.1.0" = "sha256-PE2TXNKTqf40u7/dPLu16hlbtWQnGPgcsjBRbNZWR30=";
             };
            };
            # cargoDeps = import ./Cargo.nix { inherit pkgs; };
            # cargoDeps = deps;

            nativeBuildInputs = [ pkgs.pkg-config ];

            buildInputs = [
              pkgs.wayland
              pkgs.wayland-protocols
              pkgs.libxkbcommon
              pkgs.xorg.libxcb
              pkgs.openssl
            ];

            # postInstall = wrapProgram "$out/bin/wayland-test \ --set WAYLAND_PROTOCOLS ${pkgs.wayland-protocols}/share/wayland-protocols"
          };
        };

        defaultPackage = self.packages.x86_64-linux.aw-wayland;
        # defaultPackage.x86_64-linux = self.packages.x86_64-linux.aw-wayland;
      });
}
