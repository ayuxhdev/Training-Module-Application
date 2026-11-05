import java.io.File

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

/*
 * Supply release credentials through the invoking process or CI secret store.
 * Never put credentials in this file or reuse the debug signing configuration.
 */
val releaseSigningEnvironment = listOf(
    "ANDROID_RELEASE_STORE_FILE",
    "ANDROID_RELEASE_STORE_PASSWORD",
    "ANDROID_RELEASE_KEY_ALIAS",
    "ANDROID_RELEASE_KEY_PASSWORD",
).associateWith { providers.environmentVariable(it).orNull }

val releaseKeystore = releaseSigningEnvironment["ANDROID_RELEASE_STORE_FILE"]
    ?.takeIf { it.isNotBlank() }
    ?.let { File(it) }

val validateReleaseSigningCredentials = tasks.register("validateReleaseSigningCredentials") {
    group = "verification"
    description = "Require external release signing credentials without exposing their values."
    // Capture only names and file metadata in the task action, never passwords.
    val missing = releaseSigningEnvironment.filterValues { it.isNullOrBlank() }.keys.toList()
    val keystore = releaseKeystore
    doLast {
        if (missing.isNotEmpty()) {
            throw GradleException(
                "Release signing requires these environment variables: ${missing.joinToString(", ")}",
            )
        }
        if (keystore == null || !keystore.isAbsolute || !keystore.isFile || !keystore.canRead()) {
            throw GradleException(
                "ANDROID_RELEASE_STORE_FILE must identify an absolute, readable keystore file.",
            )
        }
    }
}

// Guard actual release tasks, including aggregate/abbreviated build requests.
// This also prevents an unsigned release when AGP considers signing incomplete.
tasks.configureEach {
    if (name == "preReleaseBuild" || name == "validateSigningRelease") {
        dependsOn(validateReleaseSigningCredentials)
    }
}

android {
    namespace = "com.gardensneed.training"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.gardensneed.training"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            storeFile = releaseKeystore
            storePassword = releaseSigningEnvironment["ANDROID_RELEASE_STORE_PASSWORD"]
            keyAlias = releaseSigningEnvironment["ANDROID_RELEASE_KEY_ALIAS"]
            keyPassword = releaseSigningEnvironment["ANDROID_RELEASE_KEY_PASSWORD"]
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
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
