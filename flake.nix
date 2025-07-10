{
  description = "zv6";
  outputs = {
    self,
    nixpkgs,
    ...
  }: let
    supportedSystems = ["aarch64-darwin" "aarch64-linux" "x86_64-linux"];
    perSystem = system: let
      pkgs = import nixpkgs {inherit system;};
      venvDir = "./.venv";
    in {
      devShells.default = pkgs.mkShellNoCC {
        name = "zv6";
        packages = with pkgs; [
          zig
          qemu
          lldb
          (python312.withPackages (p:
            with p; [
              virtualenv
            ]))
        ];
        shellHook = with pkgs; ''
          SOURCE_DATE_EPOCH=$(date +%s)

          if [ -d "${venvDir}" ]; then
            echo "Skipping venv creation, '${venvDir}' already exists"
          else
            echo "Creating new venv environment in path: '${venvDir}'"
            # Note that the module venv was only introduced in python 3, so for 2.7
            # this needs to be replaced with a call to virtualenv
            ${python312Packages.python.interpreter} -m venv "${venvDir}"
          fi

          # Under some circumstances it might be necessary to add your virtual
          # environment to PYTHONPATH, which you can do here too;
          # PYTHONPATH=$PWD/${venvDir}/${python312Packages.python.sitePackages}/:$PYTHONPATH

          source "${venvDir}/bin/activate"
        '';
      };
    };
  in {
    devShells = nixpkgs.lib.genAttrs supportedSystems (
      system:
        (perSystem system).devShells
    );
  };
}
