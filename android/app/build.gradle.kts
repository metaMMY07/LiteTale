plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "opensource.wild"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973" // flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "io.github.metammy07.novels"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

// WOFF2 decoding links the NDK C++ runtime. Package the runtime from the same
// NDK as the Rust build, including its 16 KB compatible ELF alignment.
val runtimeLibraries = layout.buildDirectory.dir("generated/ndkRuntimeLibraries")
val copyNdkRuntime by tasks.registering(Copy::class) {
    val host = when {
        System.getProperty("os.name").startsWith("Windows") -> "windows-x86_64"
        System.getProperty("os.name").startsWith("Mac") -> "darwin-x86_64"
        else -> "linux-x86_64"
    }
    val sysroot = android.sdkDirectory.resolve("ndk/${android.ndkVersion}/toolchains/llvm/prebuilt/$host/sysroot/usr/lib")
    mapOf("arm64-v8a" to "aarch64-linux-android", "x86_64" to "x86_64-linux-android", "armeabi-v7a" to "arm-linux-androideabi").forEach { (abi, triple) ->
        from(sysroot.resolve("$triple/libc++_shared.so")) { into(abi) }
    }
    into(runtimeLibraries)
}
android.sourceSets.getByName("main").jniLibs.srcDir(runtimeLibraries)
tasks.named("preBuild").configure { dependsOn(copyNdkRuntime) }
