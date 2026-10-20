import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.solis.clinical.solis_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.solis.clinical.solis_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Play upload key: android/key.properties (git-ignored) points at the
    // keystore in secrets/. Without it, release builds fall back to debug keys.
    val keyProps = Properties().apply {
        val f = rootProject.file("key.properties")
        if (f.exists()) f.inputStream().use { load(it) }
    }
    signingConfigs {
        if (keyProps.getProperty("storeFile") != null) {
            create("upload") {
                storeFile = file(keyProps.getProperty("storeFile"))
                storePassword = keyProps.getProperty("storePassword")
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfig = signingConfigs.findByName("upload") ?: signingConfigs.getByName("debug")
        }
    }

    packaging {
        jniLibs {
            // On-device speech (sherpa-onnx) ships for ARM phones only. The
            // x86/x86_64 builds would add about 60 MB uncompressed for
            // emulators and a few Chromebooks; there the engine reports
            // "unsupported" and the app keeps using the platform recognizer.
            excludes += listOf(
                "lib/x86/libsherpa-onnx-jni.so",
                "lib/x86/libonnxruntime.so",
                "lib/x86_64/libsherpa-onnx-jni.so",
            )
        }
    }
}

dependencies {
    // k2-fsa sherpa-onnx 1.13.8 (Apache-2.0), official release AAR with
    // onnxruntime statically linked, vendored from
    // https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-static-link-onnxruntime-1.13.8.aar
    // SHA-256 b22c3fc1b6a45666d28892bb2f7694beeb77a8362d7ebd77c1a5431ec9435471 (see docs/NATIVE_SPEECH.md).
    implementation(files("libs/sherpa-onnx-static-link-onnxruntime-1.13.8.aar"))
    // bzip2 decoder for unpacking the downloaded model archives (Apache-2.0).
    implementation("org.apache.commons:commons-compress:1.28.0")
    // Play Integrity (Standard API) for sign-in attestation; see docs/KEYS.md.
    implementation("com.google.android.play:integrity:1.4.0")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
