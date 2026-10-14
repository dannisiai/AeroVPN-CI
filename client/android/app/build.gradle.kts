import java.io.FileInputStream
import java.util.Properties
import java.util.zip.ZipFile
import java.util.zip.ZipInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.aerovpn.aerovpn_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.aerovpn.aerovpn_client"
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

    val keystorePropertiesFile = rootProject.file("key.properties")
    val keystoreProperties = Properties()
    if (keystorePropertiesFile.exists()) {
        keystoreProperties.load(FileInputStream(keystorePropertiesFile))
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
            // else: no debug-signing fallback. A release without key.properties is
            // rejected by the signing guard below instead of silently shipping a
            // debug-signed "release".
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
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
    // Upstream libbox is a single gomobile-built AAR (see core/scripts/build_android_aar.sh,
    // scripts/make_libbox_aar.py). Only *.aar is globbed on purpose: a stale placeholder
    // classes.jar would duplicate io.nekohasekai.libbox.* and shadow the real core.
    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.aar"))))
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.annotation:annotation:1.7.1")
}

// ---------------------------------------------------------------------------
// Release signing guard.
//
// A "release" build without key.properties used to silently fall back to the
// debug signing config, so a CI or local misconfiguration would ship a
// debug-signed release without anyone noticing. Fail fast instead.
//
// The check fires on the resolved task graph rather than at configuration time:
// the buildTypes.release block runs for EVERY Gradle invocation, and an
// unconditional throw there would also break plain debug builds on machines
// without a keystore. Matches the assemble/bundle Release predicate of the
// libbox guard below. (Path mirrors the keystorePropertiesFile val inside
// android {}.)
// ---------------------------------------------------------------------------
gradle.taskGraph.whenReady {
    val packagesRelease = allTasks.any { task ->
        (task.name.startsWith("assemble") || task.name.startsWith("bundle")) && task.name.contains("Release")
    }
    if (packagesRelease && !rootProject.file("key.properties").exists()) {
        throw GradleException(
            "release build requires key.properties (see core/scripts/generate_android_keystore.ps1)"
        )
    }
}

// ---------------------------------------------------------------------------
// Release guard for the upstream core.
//
// A placeholder libbox.aar (hand-written stub classes, no jni/*.so) compiles and
// packages fine but every tunnel start fails at runtime ("Missing libbox.aar" /
// "Placeholder libbox.aar without native .so"). This repository shipped such a
// stub once, so release builds now refuse to package one.
//
// Real artifact: core/scripts/build_android_aar.sh (upstream gomobile, pinned tag).
// Debug builds are intentionally not gated so UI-only work still runs without a core.
// ---------------------------------------------------------------------------
val libboxAar = file("libs/libbox.aar")
val libboxMinimumBytes = 5L * 1024 * 1024
val libboxRequiredAbis = listOf("arm64-v8a", "armeabi-v7a")
val libboxRequiredClasses = listOf(
    // Classes AeroVpnService.kt resolves reflectively (libbox v1.13+ API surface).
    "io/nekohasekai/libbox/Libbox.class",
    "io/nekohasekai/libbox/SetupOptions.class",
    "io/nekohasekai/libbox/CommandServer.class",
    "io/nekohasekai/libbox/CommandServerHandler.class",
    "io/nekohasekai/libbox/OverrideOptions.class",
    "io/nekohasekai/libbox/PlatformInterface.class",
    // Typed Android local DNS adapter, required for bootstrap resolution.
    "io/nekohasekai/libbox/LocalDNSTransport.class",
    "io/nekohasekai/libbox/ExchangeContext.class",
)

val verifyLibboxAar by tasks.registering {
    group = "verification"
    description = "Rejects placeholder libbox.aar stubs before a release APK is packaged."
    doLast {
        fun zipEntryNames(bytes: java.io.File): List<String> {
            val names = mutableListOf<String>()
            ZipFile(bytes).use { zip ->
                val entries = zip.entries()
                while (entries.hasMoreElements()) names.add(entries.nextElement().name)
            }
            return names
        }

        if (!libboxAar.exists()) {
            throw GradleException(
                "libbox.aar is missing: the VPN core cannot run. Build it with " +
                    "core/scripts/build_android_aar.sh (or scripts/make_libbox_aar.py)."
            )
        }
        val size = libboxAar.length()
        if (size < libboxMinimumBytes) {
            throw GradleException(
                "libbox.aar is only $size bytes (< 5 MB): placeholder stub, not a gomobile " +
                    "build. Rebuild with core/scripts/build_android_aar.sh."
            )
        }
        val entryNames = try {
            zipEntryNames(libboxAar)
        } catch (exception: Exception) {
            throw GradleException("libbox.aar is not a readable AAR: ${exception.message}")
        }
        val nativeLibraries = entryNames.filter { it.startsWith("jni/") && it.endsWith(".so") }
        if (nativeLibraries.isEmpty()) {
            throw GradleException(
                "libbox.aar contains no jni/<abi>/*.so: placeholder stub, the tunnel can never " +
                    "start. Rebuild with core/scripts/build_android_aar.sh."
            )
        }
        val missingAbis = libboxRequiredAbis.filter { abi -> nativeLibraries.none { it.startsWith("jni/$abi/") } }
        if (missingAbis.isNotEmpty()) {
            throw GradleException("libbox.aar is missing native libraries for: ${missingAbis.joinToString()}")
        }
        val classNames = mutableListOf<String>()
        ZipFile(libboxAar).use { zip ->
            val classesEntry = zip.getEntry("classes.jar")
                ?: throw GradleException("libbox.aar has no classes.jar: not a valid AAR.")
            ZipInputStream(zip.getInputStream(classesEntry)).use { stream ->
                var entry = stream.nextEntry
                while (entry != null) {
                    classNames.add(entry.name)
                    entry = stream.nextEntry
                }
            }
        }
        val missingClasses = libboxRequiredClasses.filterNot { it in classNames }
        if (missingClasses.isNotEmpty()) {
            throw GradleException(
                "libbox.aar is missing libbox v1.13+ classes the native host needs: " +
                    "${missingClasses.joinToString()}. Rebuild against the pinned upstream tag."
            )
        }
        logger.lifecycle(
            "Verified libbox.aar: $size bytes, ${nativeLibraries.size} native libraries, " +
                "libbox v1.13+ classes present."
        )
    }
}

// Only release packaging is gated (commercial builds must never ship a stub).
tasks.configureEach {
    if ((name.startsWith("assemble") || name.startsWith("bundle")) && name.contains("Release")) {
        dependsOn(verifyLibboxAar)
    }
}
