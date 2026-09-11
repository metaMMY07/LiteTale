# LiteTale Android development

Android uses the existing Wild Flutter/Rust reader with selectable Wenku8 and LightNovelShelf sources. The UI
uses Material 3, Android wallpaper colors (Android 12+), a violet fallback palette and six selectable accents,
system UI fonts, rounded cards, and a phone-friendly login form. The Android
recommendation feed only requests the selected provider. First launch opens guest mode;
provider selection and independent logins live in settings. Bookcase fallback parsing is shared by Android WebView and
Windows WebView2.

Design references: [Wild](https://github.com/niuhuan/wild) and the early Flutter
version of [Novella](https://github.com/celia-sh/Novella). Novella is a visual
reference; its archived source also documents LightNovelShelf API and chapter font conventions.

## Build

Tested toolchain: Flutter 3.29.3 / Dart 3.7.2, JDK 17, Android SDK 35,
NDK 27.0.12077973, Gradle 8.13, AGP 8.12.1, Kotlin 2.2.10, Rust stable
on Windows. Set `JAVA_HOME`, `ANDROID_HOME`, `CARGO_HOME`, `RUSTUP_HOME`, and
`PUB_CACHE` for your machine as appropriate. Add Flutter and Cargo to `PATH`.
`android/local.properties` holds local SDK and Flutter paths; do not commit it.

```powershell
rustup target add aarch64-linux-android x86_64-linux-android
flutter pub get
flutter test
flutter build apk --release --target-platform android-arm64,android-x64 --split-per-abi --build-name 0.0.18-dev.1 --build-number 18
```

APK output: `build/app/outputs/flutter-apk/`. Install the arm64-v8a APK on
ARM64 phones and the x86_64 APK on an x86 Android emulator.

Application ID: `io.github.metammy07.novels`; app name: `LiteTale`.
This ID allows installation alongside upstream Wild. It does not migrate Wild's
private data. This first development build uses the local debug signing key;
configure a durable release signing key before distributing a production version.
No GitHub release is created by these commands.

`rust/build.rs` aligns the Android shared library to 16 KB for newer devices;
it does not change desktop linker options. See the Android
[page-size guidance](https://developer.android.com/guide/practices/page-sizes).
Verify packaged native libraries with `llvm-readelf -l` and the APK with
`zipalign -c -P 16 4 <apk>` before distribution.

## Validation

The 0.0.16-dev.1 build produced ARM64 (26.2 MiB) and x86_64 (26.7 MiB) APKs.
The manifest declares minimum API 21 and targets API 35. Flutter's split APK
version codes are 2016 (ARM64) and 4016 (x86_64), based on build number 16.
Both APKs passed signature, ZIP integrity, ABI, ELF segment alignment, and
16 KB ZIP alignment checks. All packaged native libraries are at least 16 KB
aligned. Runtime checks used an Android 15 emulator with 4 KB memory pages;
16 KB device execution has not been tested.

The final Flutter suite passed 33 tests with one optional live supplemental-feed
test skipped. The x86_64 APK installed and cold-started on Android 15, loaded a
real Wenku8 captcha, switched between light/dark themes, accepted keyboard input,
and allowed scrolling to the login controls in landscape. No fatal startup,
missing-plugin, or native-library loading errors appeared in the checked app log.

The widget regression suite covers portrait/landscape login with a visible
keyboard, light/dark themes, form submission, and the personal page at large
text sizes. Device checks should include login with a real Wenku8 account,
bookshelf groups, search, chapter loading, offline downloads, volume-key paging,
and changing wallpaper/system theme. Passing widget tests does not establish
network availability or successful Cloudflare verification on every device.

## 0.0.17-dev.1 changes

- Reader pagination now always advances past image markers, including markers at
  the start of an illustration chapter. Very short viewports cannot loop forever.
- Search buttons, keyboard submission and history use one request path. Loading,
  empty results, retry and pagination failures have explicit states, and older
  responses cannot replace a newer query. The first search refreshes the public
  completed-book catalog when the local index is absent or expired.
- Android appearance offers wallpaper colors and violet, blue, rose, orange,
  teal and green presets. Selection persists locally. The palette button on the
  login page and the appearance settings open the controls. Returning to the app
  refreshes wallpaper colors without replacing the navigation stack.

The Flutter suite passed 45 tests with one optional live supplemental-feed test
skipped. Added tests cover leading/consecutive image markers, short viewports,
all search submission methods, stale responses, pagination retry and accent
persistence. Targeted analysis of the new implementation and test harness passes.

The optional device test uses public Wenku8 data, requires network access and
navigates from search results into a real illustration chapter. It does not log
into an account or exercise the private bookshelf:

```powershell
flutter drive --profile -d <device> --target integration_test/android_regression_test.dart --driver test_driver/android_regression_driver.dart
```

Do not distribute APKs built with the integration test entry point. Build the
normal `lib/main.dart` release APK with the command above for installation.
