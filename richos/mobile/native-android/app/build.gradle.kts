import java.time.Duration

// :app — the Compose app. Owned by stream A1 (build plan §5.0): A2 sends its lines for this
// file through its handoff notes; A3's platform features are A1's while A3 is held.
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    // Keep the Kotlin package root independent of the permanent application ID.
    namespace = "dev.richos.android"
    // Compile against 37: the current Compose (BOM 2026.09.00, Compose 1.12) and lifecycle 2.11
    // refuse anything lower (checkAarMetadata). The TARGET stays 36, which is what the plan and
    // Google Play's rule are about; compiling against a newer SDK changes no runtime behavior.
    compileSdk = 37

    defaultConfig {
        // Permanent RichConnect application ID.
        applicationId = "dev.richos.connect"
        // minSdk 29 / targetSdk 36: build plan §3.3 (system dark theme from 29; Google Play
        // requires target 36 for new apps and updates since 2026-08-31).
        minSdk = 29
        targetSdk = 36
        // versionCode: 1 for every development build, so the fast loop's caches never churn.
        // `randroid bundle` passes -Prichos.versionCode = whole minutes from 2026-01-01T00:00Z to
        // the moment the bundle is built (UTC), so every bundle this Mac makes is numbered above
        // every earlier one, whatever branch or commit it came from (README "Version numbers").
        versionCode = providers.gradleProperty("richos.versionCode").orNull?.toInt() ?: 1
        // The version a person reads in Google Play and in Settings > Apps. Raised by hand for a
        // release; the debug build type adds "-dev".
        versionName = "1.0.0"

        // Firebase, initialized in code with no google-services plugin (build plan §3.3). The four
        // public identifiers come from Gradle properties (richos.firebase.projectId, .appId,
        // .apiKey, .senderId, e.g. in ~/.gradle/gradle.properties); left empty, the app still
        // builds and reports notifications as platform-unavailable.
        for (key in listOf("projectId", "appId", "apiKey", "senderId")) {
            val value = providers.gradleProperty("richos.firebase.$key").orElse("").get()
            buildConfigField("String", "FIREBASE_" + key.replace(Regex("([A-Z])"), "_$1").uppercase(), "\"$value\"")
        }
    }

    // Release signing with the Google Play UPLOAD key (Play App Signing holds the app signing key).
    // The four values arrive only as Gradle properties from the process environment
    // (ORG_GRADLE_PROJECT_richos.upload.*), set by richos-hq/scripts/with-android-signing.py from
    // protected storage outside every repository. Nothing here, in gradle.properties or in Git
    // names a password or a keystore path. Without them the release build stays unsigned, as it
    // always was, and `randroid bundle` refuses to produce a bundle.
    val upload = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
        .associateWith { providers.gradleProperty("richos.upload.$it").orNull?.takeIf(String::isNotBlank) }
    if (upload.values.all { it != null }) {
        signingConfigs.create("upload") {
            storeFile = file(upload.getValue("storeFile")!!)
            storePassword = upload.getValue("storePassword")
            keyAlias = upload.getValue("keyAlias")
            keyPassword = upload.getValue("keyPassword")
            storeType = "PKCS12"
        }
    }

    buildTypes {
        debug {
            versionNameSuffix = "-dev"
        }
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("upload")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

// Robolectric's Android 36 sandbox needs a Java 21 runtime, and Gradle would otherwise pick a
// Java 17 toolchain for the tests to match the bytecode target (measured: "Android SDK 36
// requires Java 21 (have Java 17)" with Homebrew's openjdk@17 on this Mac). The bytecode stays 17.
tasks.withType<Test>().configureEach {
    // A hung test (a blocked main looper, say) fails the run instead of holding the Mac.
    timeout.set(Duration.ofMinutes(10))
    javaLauncher.set(javaToolchains.launcherFor { languageVersion.set(JavaLanguageVersion.of(21)) })
    // Robolectric reaches into FileDescriptor internals on Java 21 (measured: IllegalAccessException
    // on jdk.internal.access.SharedSecrets without these).
    jvmArgs(
        "--add-exports=java.base/jdk.internal.access=ALL-UNNAMED",
        "--add-opens=java.base/jdk.internal.access=ALL-UNNAMED",
        "--add-opens=java.base/java.io=ALL-UNNAMED",
        "--add-opens=java.base/java.lang=ALL-UNNAMED",
    )
}

dependencies {
    implementation(project(":core"))
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(platform(libs.firebase.bom))
    implementation(libs.firebase.messaging)
    // The pairing scanner (ui/pairing): CameraX for the preview and frames, ZXing to read the QR on
    // the phone. Both open source, no network, no Google account and no Play services. Written as
    // coordinates, not catalog entries, so this stream touches only these lines of the shared files.
    implementation("androidx.camera:camera-camera2:1.6.2")
    implementation("androidx.camera:camera-lifecycle:1.6.2")
    implementation("androidx.camera:camera-view:1.6.2")
    implementation("com.google.zxing:core:3.5.4")

    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(platform(libs.compose.bom))
    testImplementation(libs.compose.ui.test.junit4)
    debugImplementation(libs.compose.ui.test.manifest)
}
