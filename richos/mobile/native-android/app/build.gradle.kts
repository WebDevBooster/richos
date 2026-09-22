// :app — the Compose app. Owned by stream A1 (build plan §5.0): A2 and A3 send their lines
// for this file through their handoff notes.
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    // The Kotlin package root. `native` is a Java keyword, so the development application ID
    // below cannot double as the namespace.
    namespace = "dev.richos.android"
    // Compile against 37: the current Compose (BOM 2026.09.00, Compose 1.12) and lifecycle 2.11
    // refuse anything lower (checkAarMetadata). The TARGET stays 36, which is what the plan and
    // Google Play's rule are about; compiling against a newer SDK changes no runtime behavior.
    compileSdk = 37

    defaultConfig {
        // Development ID (Rich, 2026-09-22). The production IDs are the CEO's, later.
        applicationId = "dev.richos.native.android"
        // minSdk 29 / targetSdk 36: build plan §3.3 (system dark theme from 29; Google Play
        // requires target 36 for new apps and updates since 2026-08-31).
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0-dev"
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
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

    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(platform(libs.compose.bom))
    testImplementation(libs.compose.ui.test.junit4)
    debugImplementation(libs.compose.ui.test.manifest)
}
