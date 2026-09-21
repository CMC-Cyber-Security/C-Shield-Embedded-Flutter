import java.io.File
group = "com.cmc.c_shield_embedded.c_shield_embedded"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.3.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.0.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

// Capture plugin's own android dir before entering allprojects scope.
// gradle.allprojects propagates local-repo to ALL projects in the build
// (including consumer app's :app module), so no extra Gradle config needed.
val pluginAndroidDir = project.projectDir

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

// Locate c-shield-sdk-<variant>.aar — two possible locations:
//   1. android/libs/  (plugin development, local build)
//   2. <consumer-app>/android/app/libs/  (customer integration via pub.dev)
fun resolveAarForVariant(variant: String): File? {
    val localAar = file("${project.projectDir}/libs/cshield-embedded-${variant}.aar")
    if (localAar.exists()) return localAar

    val consumerAar = File(rootProject.projectDir, "app/libs/cshield-embedded-${variant}.aar")
    if (consumerAar.exists()) return consumerAar

    return null
}

// Fail early with a clear message if either AAR variant is not found
tasks.named("preBuild").configure {
    doFirst {
        listOf("debug", "release").forEach { variant ->
            if (resolveAarForVariant(variant) == null) {
                throw GradleException("""
================================================================================
❌  cshield-embedded-${variant}.aar not found!

    Place both AAR variants in your Android app's libs folder:
      android/app/libs/cshield-embedded-debug.aar
      android/app/libs/cshield-embedded-release.aar

    Then declare them in android/app/build.gradle:
      dependencies {
          debugImplementation(files("libs/cshield-embedded-debug.aar"))
          releaseImplementation(files("libs/cshield-embedded-release.aar"))
      }

    Contact CMC to obtain the AARs built for your app's signing certificate.
================================================================================
""")
            }
        }
    }
}

android {
    namespace = "com.cmc.c_shield_embedded.c_shield_embedded"

    compileSdk = 34

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")


    // Use the matching AAR variant on the compile classpath so the plugin's
    // bridge code always compiles against the same binary the consumer ships.
    debugCompileOnly(files(resolveAarForVariant("debug")))
    releaseCompileOnly(files(resolveAarForVariant("release")))
    // OkHttp is declared as 'runtime' scope in the AAR POM, so it does not land on the
    // compile classpath automatically. We need it here to compile our bridge code that
    // calls AIPCore.normalizeBodyForSigning(okhttp3.Request) and builds OkHttpClient.
    // Version must match what the AAR bundles (declared in its POM).
    implementation("com.squareup.okhttp3:okhttp:4.11.0")
}
