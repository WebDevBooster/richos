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
    compileSdk = 36

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
