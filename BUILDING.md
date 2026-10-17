# Building OpenBubbles

These are the steps to build the Linux desktop app and the Android APK from source. They were
written on Fedora 44 (x86_64), so package names are Fedora's; other distros need the
equivalents.

The app is Flutter with a Rust core (`rust/`, which pulls in `rustpush/` and its own
submodules). Cargokit (`rust_builder/`) compiles the Rust automatically during
`flutter build`, so there is no separate Rust build step.

## 1. Clone with submodules

The Rust code lives in nested submodules (`rustpush` has six of its own), so a plain clone
won't build:

```sh
git clone --recurse-submodules https://github.com/gavinsan33/openbubbles-app.git
# or, in an existing clone:
git submodule update --init --recursive
```

rustpush also compiles in FairPlay certificates from `rustpush/certs/fairplay/`, which isn't in
git. Fill it with placeholder copies of the committed legacy certificate:

```sh
rust/fairplay-placeholders.sh
```

## 2. Toolchains (mise)

Tool versions are pinned in `mise.toml`: Flutter 3.24.0, Java (Temurin 21), Rust stable,
protoc, and `flutter_rust_bridge_codegen` 2.3.0. Use these versions rather than whatever is
installed system-wide: the Dart dependencies are locked against Flutter 3.24.0, and
`flutter_rust_bridge` must exactly match its codegen version (2.3.0).

```sh
# install mise (https://mise.jdx.dev), then hook it into your shell, e.g. in ~/.zshrc:
eval "$(mise activate zsh)"

cd openbubbles-app
mise trust
mise install
```

The Rust entry in `mise.toml` uses rustup, so you also need rustup itself
(https://rustup.rs). `protoc` is required: `rust/build.rs` compiles protobufs with it.

## 3. System packages

```sh
# C/C++ toolchain and the Flutter Linux build tools
sudo dnf install gcc make clang cmake ninja-build pkgconf-pkg-config jq

# perl modules for building the vendored OpenSSL (openssl-sys `vendored` feature)
sudo dnf install perl-core

# libraries the Flutter desktop plugins link against
sudo dnf install gtk3-devel webkit2gtk4.1-devel mpv-devel libnotify-devel libepoxy-devel \
    libayatana-appindicator-gtk3-devel
```

What each library is for: `webkit2gtk4.1-devel` → desktop_webview_auth, `mpv-devel` +
`libepoxy-devel` → media_kit, `libnotify-devel` → local_notifier, and
`libayatana-appindicator-gtk3-devel` → tray_manager / system_tray.

### Fedora 43+: CA bundle path

Fedora no longer ships `/etc/pki/tls/certs/ca-bundle.crt`, but some tools in the build still
look for that path to verify TLS certificates. Recreate it as a symlink:

```sh
sudo ln -s /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem /etc/pki/tls/certs/ca-bundle.crt
```

## 4. Linux desktop build

```sh
flutter build linux --release
./build/linux/x64/release/bundle/bluebubbles
```

`linux/build.sh` does the same build, injects the version into `version.json`, and packs
the bundle into `bluebubbles-linux-<arch>.tar`.

### Releasing

Releases normally come from CI. Push a tag named after `pubspec.yaml`'s version, on a commit on
`main`:

```sh
git tag v1.15.0+231 && git push origin v1.15.0+231
```

`.github/workflows/release.yml` then builds the RPM (in a Fedora container) and the signed
`prod` APK. Once both build, it publishes the RPM to the dnf repo and creates a GitHub Release
with the RPM, the Linux bundle and the APK. Running the workflow by hand (Actions → Release →
Run workflow) builds everything without publishing. The signing keys and the
openbubbles-rpm deploy key are repository secrets, listed at the top of the workflow.

To release from your own machine instead, `linux/rpm/release.sh` builds the app, packages it as a signed RPM, and publishes it to the
dnf repo on GitHub Pages (gavinsan33/openbubbles-rpm). Before running it:

```sh
sudo dnf install rpm-build rpm-sign createrepo_c
```

- Import the signing key (`263DA61CD7D9F531226ACABFB081349D8D5305BF`, "OpenBubbles RPM
  signing") into your GPG keyring. The release script refuses to run without it.
- Set up push access to `gavinsan33/openbubbles-rpm` (e.g. `gh auth login`).
- Bump the build number (the part after `+` in `pubspec.yaml`'s `version:`) for every
  release. The script refuses to republish an existing version.

## 5. Android build

1. Install Android Studio. In its SDK Manager, install:
   - an SDK platform for API 36 (`compileSdk 36`)
   - Android SDK Command-line Tools
   - NDK 26.1.10909125 (the Android Gradle Plugin's default; cargokit uses it to cross-compile
     the Rust)
2. Point Flutter at it and accept the licenses:
   ```sh
   flutter doctor --android-licenses
   flutter doctor
   ```
   `android/local.properties` (git-ignored) is generated with `sdk.dir` and `flutter.sdk`.
   If Flutter can't find the SDK, set `sdk.dir=$HOME/Android/Sdk` there yourself.
3. Add the Rust Android target:
   ```sh
   rustup target add aarch64-linux-android
   ```
4. Signing: release builds of the `prod` and `beta` flavors are signed with the key named in
   `android/key.properties` (git-ignored):
   ```properties
   storeFile=/home/<you>/.android-keys/openbubbles-release.jks
   storePassword=...
   keyAlias=...
   keyPassword=...
   ```
   Without this file, release builds of those flavors have no signing key. Debug builds and
   the `joel`/`tanay` flavors use the debug key.
5. Build:
   ```sh
   flutter build apk --flavor prod --release --target-platform android-arm64 --split-per-abi
   ```
   The APK lands in `build/app/outputs/flutter-apk/`. To install it, use `adb` from
   `~/Android/Sdk/platform-tools` (add that directory to your `PATH`).

## Regenerating the Rust bindings

The Dart bindings (`lib/src/rust/`) and the Kotlin UniFFI bindings
(`android/app/src/main/kotlin/uniffi/`) are committed to the repo. You only need to
regenerate them after changing the Rust API in `rust/src/api/`:

```sh
flutter_rust_bridge_codegen generate      # Dart bindings, configured by flutter_rust_bridge.yaml
(cd rust && ./build-uniffi.sh)            # Kotlin bindings
```
