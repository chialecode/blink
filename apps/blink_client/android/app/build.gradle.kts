plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

fun compareNdkVersionStrings(a: String, b: String): Int {
    val aParts = a.split(".").map { it.toIntOrNull() ?: 0 }
    val bParts = b.split(".").map { it.toIntOrNull() ?: 0 }
    val maxLen = maxOf(aParts.size, bParts.size)
    for (i in 0 until maxLen) {
        val av = aParts.getOrElse(i) { 0 }
        val bv = bParts.getOrElse(i) { 0 }
        if (av != bv) {
            return av.compareTo(bv)
        }
    }
    return a.compareTo(b)
}

val resolvedNdkVersion: String =
    project
        .findProperty("flutter.installedNdkVersions")
        ?.toString()
        ?.split(",")
        ?.map(String::trim)
        ?.filter(String::isNotEmpty)
        ?.maxWithOrNull(Comparator(::compareNdkVersionStrings))
        ?: flutter.ndkVersion

android {
    namespace = "io.github.chialecode.blink_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = resolvedNdkVersion

    buildFeatures {
        resValues = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.chialecode.blink"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    flavorDimensions += "channel"
    productFlavors {
        create("blink") {
            dimension = "channel"
            applicationId = "io.github.chialecode.blink"
            resValue("string", "app_name", "BLINK")
        }
        create("blinkDev") {
            dimension = "channel"
            applicationId = "io.github.chialecode.blink.dev"
            resValue("string", "app_name", "BLINK Dev")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
