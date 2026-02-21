# mizemoon (RustDesk fork) – Build Notes

## Quick Context
- This repo is a rebrand of `rustdesk/rustdesk` to **mizemoon**.
- Flutter UI is used; Rust core builds the native library.
- Linux `.deb` and Android APK builds were validated in this workspace.

## Paths Used Here
- Flutter SDK: `/home/mohsen/flutter/bin/flutter`
- Android SDK: `/home/mohsen/Android/Sdk`
- Android NDK: `/home/mohsen/Android/Sdk/ndk/29.0.14206865`
- VCPKG: `/home/mohsen/vcpkg`
- Android keystore: `/home/mohsen/Desktop/androidKeys/shuttle/vanaboom.key`  
  (Passwords are **not** stored here; keep them private.)

## Linux (.deb) Build (with hwcodec)
### System deps (Mint/Ubuntu)
Install ffmpeg + gtk + gstreamer + others as needed (example):
```
sudo apt install -y \
  libgtk-3-dev libappindicator3-dev libclang-dev libpipewire-0.3-dev \
  libpulse-dev libusb-1.0-0-dev libxdo-dev libxrandr-dev \
  gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  libva-dev libva-drm2 libva-x11-2 \
  libvpx-dev libyuv-dev libaom-dev libopus-dev \
  libavcodec-dev libavformat-dev libavutil-dev libswscale-dev
```

### hwcodec build uses pkg-config (not vcpkg) on Linux
- Local crate exists at `libs/hwcodec`.
- `libs/scrap/Cargo.toml` points to `path = "../hwcodec"`.
- `libs/hwcodec/build.rs` uses pkg-config on Linux when:
  - `HWCODEC_USE_PKG_CONFIG=1` **or** `VCPKG_ROOT` missing.
- `res/pkgconfig/libyuv.pc` exists because Mint’s `libyuv-dev` lacks a `.pc`.
  - Use `PKG_CONFIG_PATH=/home/mohsen/dev/mizemoon/app/res/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig`.

### Build commands
```
export PATH=/home/mohsen/flutter/bin:$PATH
export PKG_CONFIG_PATH=/home/mohsen/dev/mizemoon/app/res/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig
export HWCODEC_USE_PKG_CONFIG=1

cargo build --features "hwcodec,flutter,linux-pkg-config" --lib --release
python3 build.py --flutter --hwcodec --skip-cargo
```
Output: `mizemoon-*.deb` in repo root.

## Android APK Build (arm64)
### Env
```
export ANDROID_SDK_ROOT=/home/mohsen/Android/Sdk
export ANDROID_NDK_HOME=/home/mohsen/Android/Sdk/ndk/29.0.14206865
export ANDROID_NDK_ROOT=$ANDROID_NDK_HOME
export VCPKG_ROOT=/home/mohsen/vcpkg
export PATH=/home/mohsen/flutter/bin:$PATH
```

### Build Android deps
```
./flutter/build_android_deps.sh arm64-v8a
```

### Rust (Android) build
```
rustup target add aarch64-linux-android armv7-linux-androideabi
cargo install cargo-ndk

cargo ndk --platform 21 --target aarch64-linux-android \
  build --release --features flutter,hwcodec
```

Copy the native libs:
```
mkdir -p flutter/android/app/src/main/jniLibs/arm64-v8a
cp target/aarch64-linux-android/release/librustdesk.so \
  flutter/android/app/src/main/jniLibs/arm64-v8a/
cp $ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so \
  flutter/android/app/src/main/jniLibs/arm64-v8a/
strip flutter/android/app/src/main/jniLibs/arm64-v8a/librustdesk.so
```

### Flutter build
```
cd flutter
flutter clean
flutter pub get
flutter build apk --target-platform android-arm64 --release
```

### Maven/TLS workaround
If Gradle fails fetching from Maven Central, `flutter/android/build.gradle` already includes:
```
maven { url 'https://maven.aliyun.com/repository/public' }
maven { url 'https://maven.aliyun.com/repository/google' }
mavenCentral()
```

### Kotlin version
`flutter/android/settings.gradle` uses:
```
id "org.jetbrains.kotlin.android" version "1.9.10"
```

## Windows Build (Flutter, x64)
### Prerequisites
- Visual Studio 2022 with `Desktop development with C++` workload.
- LLVM (for `libclang.dll` used by Rust bindgen/hwcodec), e.g. `winget install LLVM.LLVM`.
- Rust (MSVC toolchain): `rustup default stable-x86_64-pc-windows-msvc`
- Flutter SDK for Windows and desktop enabled:
  - `flutter config --enable-windows-desktop`
  - `flutter doctor -v`
- vcpkg with required libs:
  - `vcpkg install --classic ffmpeg[amf,nvcodec,qsv]:x64-windows-static mfx-dispatch:x64-windows-static libvpx:x64-windows-static libyuv:x64-windows-static opus:x64-windows-static aom:x64-windows-static`

### Env (PowerShell example)
```powershell
$env:VCPKG_ROOT = "C:\vcpkg"
$env:LIBCLANG_PATH = "C:\Program Files\LLVM\bin"
$env:PATH = "C:\src\flutter\bin;$env:USERPROFILE\.cargo\bin;$env:PATH"
```

### Build command
```powershell
python build.py --flutter --hwcodec
```

Or run the helper script from repo root (checks prerequisites first):
```powershell
.\build-windows.ps1 -VcpkgRoot C:\vcpkg
```

For automatic tool installation/setup (Rust, Flutter, vcpkg):
```powershell
.\setup-windows-tools.ps1 -VcpkgRoot C:\dev\vcpkg -InstallVcpkgDeps
```

Or let build script trigger setup automatically:
```powershell
.\build-windows.ps1 -AutoSetup -VcpkgRoot C:\dev\vcpkg -InstallMissingVcpkgDeps
```

For verbose vcpkg diagnostics (especially when ffmpeg takes too long), add:
```powershell
.\build-windows.ps1 -AutoSetup -VcpkgRoot C:\dev\vcpkg -InstallMissingVcpkgDeps -VcpkgDebug
```

To auto-install missing Rust/Flutter tools too (full setup mode):
```powershell
.\build-windows.ps1 -AutoSetup -AutoSetupAllTools -VcpkgRoot C:\dev\vcpkg -InstallMissingVcpkgDeps
```

Include Visual C++ Build Tools in auto setup if needed:
```powershell
.\build-windows.ps1 -AutoSetup -AutoSetupAllTools -InstallVisualCpp -VcpkgRoot C:\dev\vcpkg -InstallMissingVcpkgDeps
```

### Outputs
- Main app exe: `flutter/build/windows/x64/runner/Release/mizemoon.exe`
- Portable/installer exe: `mizemoon-<version>-install.exe` (repo root)

### Notes
- `build.py` now uses the active Python (`sys.executable`) for `pip` and helper scripts, so `python3/pip3` aliases are not required on Windows.
- If you only want the Flutter exe and want to skip portable packing:
  - `python build.py --flutter --hwcodec --skip-portable-pack`
- `-AutoSetup` in `build-windows.ps1` focuses on project deps (vcpkg + optional Visual C++), not full Rust/Flutter installation.
- For full automatic tool install (Rust/Flutter/vcpkg/LLVM for libclang), use `-AutoSetup -AutoSetupAllTools` or run `setup-windows-tools.ps1` first.
- `build-windows.ps1` tries to load Visual C++ environment automatically via `vswhere` + `vcvars64.bat` if `cl.exe` is not already in PATH.
- `build-windows.ps1` now refreshes Flutter metadata before build (`.flutter-plugins*` cleanup + `flutter pub get`) to reduce plugin file lock/write failures.
- On Windows, Flutter plugin builds require symlink support. Enable Developer Mode (`start ms-settings:developers`) or run the shell as Administrator.

## Rebrand reminders
- App name: **mizemoon** (not rustdesk).
- Rendezvous servers and pubkey customized in `libs/hbb_common/src/config.rs`.
- Linux sciter path uses `/usr/share/mizemoon` with fallback to `/usr/share/rustdesk`.
