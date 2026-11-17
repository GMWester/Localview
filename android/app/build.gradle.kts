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

    // A permanent release key (CI secret ANDROID_KEYSTORE_B64) keeps in-app updates
    // installable: Android only accepts an update signed with the same key.
    val releaseKeystore = System.getenv("LV_KEYSTORE")?.takeIf { it.isNotEmpty() && file(it).exists() }
    signingConfigs {
        create("release") {
            if (releaseKeystore != null) {
                storeFile = file(releaseKeystore)
                storePassword = System.getenv("LV_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("LV_KEY_ALIAS") ?: "localview"
                keyPassword = System.getenv("LV_KEY_PASSWORD") ?: System.getenv("LV_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (releaseKeystore != null) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
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

dependencies {
    implementation("androidx.core:core-ktx:1.16.0")
}

// Jetpack XR SceneCore: Virtual-Desktop-style theater (Full Space + large screen).
dependencies {
    implementation("androidx.xr.scenecore:scenecore:1.0.0")
    implementation("org.khronos.openxr:openxr_loader_for_android:1.1.65")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.9.4")
}
