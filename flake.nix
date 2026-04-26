{
  description = "zv6";
  inputs.nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";
  outputs =
    {
      nixpkgs,
      ...
    }:
    let
      supportedSystems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      perSystem =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          devShells.default = pkgs.mkShellNoCC {
            name = "zv6";
            packages = with pkgs; [
              zig
              zls
              qemu
              lldb
              python3
              perl
              llvmPackages.bintools # for objdump and symbolizer
            ];
          };
        };
    in
    {
      devShells = nixpkgs.lib.genAttrs supportedSystems (system: (perSystem system).devShells);
    };
}
