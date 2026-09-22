plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.roborazzi) apply false
}

// Build output lives outside the source tree (richos/mobile/AGENTS.md). `bin/randroid`
// passes `-Prichos.out=<dir on the external SSD>`; a bare `./gradlew` falls back to the
// ignored in-tree `build/` directories.
val out = providers.gradleProperty("richos.out").orNull
if (out != null) {
    allprojects {
        layout.buildDirectory.set(file("$out/${if (path == ":") "root" else path.removePrefix(":").replace(':', '/')}"))
    }
}
