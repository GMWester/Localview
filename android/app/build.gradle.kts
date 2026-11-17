// LAN and WAN variants install side by side: -P lvMode=lan|wan|combined (flutter: --android-project-arg lvMode=wan)
val lvMode = ((project.findProperty("lvMode") as String?) ?: "lan").lowercase()

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.localview.localview"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // Native OpenXR client for PC VR streaming (src/main/cpp).
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
    buildFeatures {
        prefab = true
    }

    defaultConfig {
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
        applicationId = "io.localview.localview.$lvMode"
        manifestPlaceholders["appLabel"] = when (lvMode) {
            "combined" -> "Localview"
            else -> "Localview ${lvMode.uppercase()}"
        }
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 29 // Quest 2+ / Android XR; AImageReader GPU buffers
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// Jetpack XR SceneCore: Virtual-Desktop-style theater (Full Space + large screen).
dependencies {
    implementation("androidx.xr.scenecore:scenecore:1.0.0")
    implementation("org.khronos.openxr:openxr_loader_for_android:1.1.65")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.9.4")
}
