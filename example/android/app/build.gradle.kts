import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load key.properties into project ext so project.property() can resolve them.
val keyPropertiesFile = rootProject.file("key.properties")
if (keyPropertiesFile.exists()) {
    Properties().also { it.load(keyPropertiesFile.inputStream()) }
        .forEach { k, v -> ext.set(k.toString(), v.toString()) }
}

android {
    namespace = "com.cmc.example.cshieldembedded"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        create("debug-build") {
            storeFile = file("../keystore/flutter-cshield-debug.jks")
            storePassword = project.property("DEBUG_KEYSTORE_PASSWORD") as String
            keyAlias = project.property("DEBUG_KEY_ALIAS") as String
            keyPassword = project.property("DEBUG_KEYSTORE_PASSWORD") as String
        }

        create("release-build") {
            storeFile = file("../keystore/flutter-cshield-release.jks")
            storePassword = project.property("RELEASE_KEYSTORE_PASSWORD") as String
            keyAlias = project.property("RELEASE_KEY_ALIAS") as String
            keyPassword = project.property("RELEASE_KEYSTORE_PASSWORD") as String
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.cmc.example.cshieldembedded"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("debug-build")
        }
        release {
            signingConfig = signingConfigs.getByName("release-build")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // c-shield-sdk AAR must be placed in android/app/libs/ by the consumer.
    // The plugin uses compileOnly — this implementation provides the runtime classes.
    // Use the matching variant so the AAR's signing-certificate check passes.
    debugImplementation(files("libs/cshield-embedded-debug.aar"))
    releaseImplementation(files("libs/cshield-embedded-release.aar"))

    implementation("androidx.work:work-runtime-ktx:2.9.0")
    implementation("com.squareup.retrofit2:converter-gson:2.9.0")
}

// The `integration_test` package pulls in androidx.test.espresso:espresso-core:3.2+,
// whose 3.2.0 resolution predates per-artifact manifest namespaces and collides with
// espresso-idling-resource:3.2.0 under AGP's strict namespace uniqueness check. Force
// both to a matching newer release so they resolve to distinct namespaces.
configurations.all {
    resolutionStrategy {
        force("androidx.test.espresso:espresso-core:3.6.1")
        force("androidx.test.espresso:espresso-idling-resource:3.6.1")
    }
}


flutter {
    source = "../.."
}
