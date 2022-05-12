final: prev:
let
  pkgs = final;
  rustPlatformFor = rust: prev.makeRustPlatform {
    cargo = rust;
    rustc = rust;
    # override stdenv.targetPlatform here, if neccesary
  };
in {
  # nixpkgs + musl problems
  postgresql =
    (prev.postgresql.override { enableSystemd = false; }).overrideAttrs
    (o: { doCheck = false; });

  openssh = (if prev.stdenv.hostPlatform.isMusl then
    (prev.openssh.override {
      # todo: fix libredirect musl
      libredirect = "";
    }).overrideAttrs (o: { doCheck = !prev.stdenv.hostPlatform.isMusl; })
  else
    prev.openssh);

  # jemalloc = prev.jemalloc.overrideAttrs (_: {
  #   nativeBuildInputs = [ final.autoconf ];
  #   preConfigure = "./autogen.sh";
  #   src = final.fetchFromGitHub {
  #     owner = "jemalloc";
  #     repo = "jemalloc";
  #     rev = "011449f17bdddd4c9e0510b27a3fb34e88d072ca";
  #     sha256 = "FwMs8m/yYsXCEOd94ZWgpwqtVrTLncEQCSDj/FqGewE=";
  #   };
  # });

  git = prev.git.overrideAttrs
    (o: { doCheck = o.doCheck && !prev.stdenv.hostPlatform.isMusl; });

  # Overrides for dependencies

  sodium-static =
    pkgs.libsodium.overrideAttrs (o: { dontDisableStatic = true; });

  rocksdb = (prev.rocksdb.override {
    snappy = null;
    lz4 = null;
    zstd = null;
    bzip2 = null;
  }).overrideAttrs (_: {
    cmakeFlags = [
      "-DPORTABLE=1"
      "-DWITH_JEMALLOC=0"
      "-DWITH_JNI=0"
      "-DWITH_BENCHMARK_TOOLS=0"
      "-DWITH_TESTS=1"
      "-DWITH_TOOLS=0"
      "-DWITH_BZ2=0"
      "-DWITH_LZ4=0"
      "-DWITH_SNAPPY=0"
      "-DWITH_ZLIB=0"
      "-DWITH_ZSTD=0"
      "-DWITH_GFLAGS=0"
      "-DUSE_RTTI=1"
    ];
  });

  # Rust stuff (for marlin_plonk_bindings_stubs)
  crypto-rust-musl = ((final.crypto-rust.override { targets = [ "x86_64-unknown-linux-musl" ]; }).overrideAttrs
    (oa: {
      nativeBuildInputs = [ final.makeWrapper ];
      buildCommand = oa.buildCommand + ''
        for exe in $(find "$out/bin" -type f -or -type l); do
          wrapProgram "$exe" --prefix LD_LIBRARY_PATH : ${final.gcc-unwrapped.lib}/lib
        done
      '';
    })) // {
      inherit (prev.rust) toRustTarget toRustTargetSpec;
    };

  crypto-rust = (final.rustChannelOf rec {
    channel = (builtins.fromTOML (builtins.readFile ../src/lib/crypto/rust-toolchain.toml)).toolchain.channel;
    # update the hash if the assertion fails
    sha256 = assert channel == "1.58.0"; "sha256-eQBpSmy9+oHfVyPs0Ea+GVZ0fvIatj6QVhNhYKOJ6Jk=";
  }).rust;

  # Dependencies which aren't in nixpkgs and local packages which need networking to build
  kimchi_bindings_stubs = (rustPlatformFor (if pkgs.stdenv.hostPlatform.isMusl then
    final.crypto-rust-musl
  else
    final.crypto-rust)).buildRustPackage {
      pname = "kimchi_bindings_stubs";
      version = "0.1.0";
      src = ../src/lib/crypto;
      nativeBuildInputs = [ pkgs.ocamlPackages_mina.ocaml ];
      # FIXME: tests fail
      doCheck = false;
      cargoLock.lockFile = ../src/lib/crypto/Cargo.lock;
    };

  go-capnproto2 = pkgs.buildGoModule rec {
    pname = "capnpc-go";
    version = "v3.0.0-alpha.1";
    vendorSha256 = "sha256-jbX/nnlnQoItFXFL/MZZKe4zAjM/EA3q+URJG8I3hok=";
    src = final.fetchFromGitHub {
      owner = "capnproto";
      repo = "go-capnproto2";
      rev = "v3.0.0-alpha.1";
      hash = "sha256-afdLw7of5AksR4ErCMqXqXCOnJ/nHK2Lo4xkC5McBfM";
    };
  };

  libp2p_ipc_go = pkgs.stdenv.mkDerivation {
    # todo: buildgomodule?
    name = "libp2p_ipc-go";
    buildInputs = [ pkgs.capnproto pkgs.go-capnproto2 ];
    src = ../src/libp2p_ipc;
    buildPhase = ''
      capnp compile -ogo -I${pkgs.go-capnproto2.src}/std libp2p_ipc.capnp
    '';
    installPhase = ''
      mkdir $out
      cp go.mod go.sum *.go $out/
    '';
  };

  # Jobs/Test/Libp2pUnitTest
  libp2p_helper = pkgs.buildGoModule {
    pname = "libp2p_helper";
    version = "0.1";
    src = ../src/app/libp2p_helper/src;
    runVend = true; # missing some schema files
    doCheck = false; # TODO: tests hang
    vendorSha256 =
      # sanity check, to make sure the fixed output drv doesn't keep working
      # when the inputs change
      if builtins.hashFile "sha256" ../src/app/libp2p_helper/src/go.mod
      == "4ce9e2efa7e35cce9b7b131bef15652830756f6f6da250afefd4751efa1d6565"
      && builtins.hashFile "sha256" ../src/app/libp2p_helper/src/go.sum
      == "8b90b3cee4be058eeca0bc9a5a2ee88d62cada9fb09785e0ced5e5cea7893192" then
        "sha256-MXLfE122UCNizqvGUu6WlThh1rnZueTqirCzaEWmbno="
      else
        pkgs.lib.warn
        "Please update the hashes in ${__curPos.file}#${toString __curPos.line}"
        pkgs.lib.fakeHash;
    NO_MDNS_TEST = 1; # no multicast support inside the nix sandbox
    overrideModAttrs = n: {
      # remove libp2p_ipc from go.mod, inject it back in postconfigure
      postConfigure = ''
        sed -i 's/.*libp2p_ipc.*//' go.mod
      '';
    };
    postConfigure = ''
      chmod +w vendor
      cp -r --reflink=auto ${pkgs.libp2p_ipc_go}/ vendor/libp2p_ipc
      sed -i 's/.*libp2p_ipc.*//' go.mod
    '';
  };

  kimchi-rust-wasm = ((final.rustChannelOf {
    # todo: read src/lib/crypto/kimchi_bindings/wasm/rust-toolchain.toml
    channel = "nightly";
    date = "2021-11-16";
    sha256 = "sha256-ErdLrUf9f3L/JtM5ghbefBMgsjDMYN3YHDTfGc008b4=";
  }).rust.override {
    targets = [ "wasm32-unknown-unknown" ];
    # rust-src is needed for -Zbuild-std
    extensions = [ "rust-src" ];
  });

  # TODO: these should be built for both web and nodejs, see the dune files
  # at ../src/lib/crypto/kimchi_bindings/js/{chrome,node_js}/dune
  plonk_wasm = (rustPlatformFor final.kimchi-rust-wasm).buildRustPackage {
    pname = "plonk_wasm";
    version = "0.1.0";
    src = final.lib.sourceByRegex ../src [
      "^lib(/crypto(/kimchi_bindings(/wasm(/.*)?)?)?)?$"
      "^lib(/crypto(/proof-systems(/.*)?)?)?$"
      "^external(/wasm-bindgen-rayon(/.*)?)?"
    ];
    sourceRoot = "source/lib/crypto/kimchi_bindings/wasm";
    nativeBuildInputs = [ pkgs.wasm-pack pkgs.wasm-bindgen-cli ];
    cargoLock.lockFile = ../src/lib/crypto/kimchi_bindings/wasm/Cargo.lock;
    RUSTFLAGS = "-C target-feature=+atomics,+bulk-memory,+mutable-globals -C link-arg=--no-check-features -C link-arg=--max-memory=4294967296";
    # adapted from cargoBuildHook
    # FIXME: wasm-pack can't find wasm-bindgen
    buildPhase = ''
      runHook preBuild
      # TODO: remove: this file also adds -Zbuild-std
      sed -i '/build-std/d' .cargo/config
      (
      set -x
      wasm-pack build --mode no-install --target nodejs --out-dir $out ./. -- --features nodejs
      )
      runHook postBuild
    '';
    # FIXME: cargo flag -Zbuild-std=panic_abort,std doesn't work
    dontCargoBuild = true;
    cargoBuildFeatures = ["nodejs"];
  };
}
