// :cli — the headless command line over the real :core (build plan §3.1 loop L1′).
// `bin/randroid headless …` runs the installed launcher directly, so a logic check costs one
// JVM start and no Gradle configuration.
plugins {
    alias(libs.plugins.kotlin.jvm)
    application
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

application {
    applicationName = "randroid-headless"
    mainClass.set("dev.richos.android.cli.MainKt")
    // A short-lived process: stop at the first JIT tier, a small serial heap, class data sharing.
    applicationDefaultJvmArgs = listOf("-XX:TieredStopAtLevel=1", "-XX:+UseSerialGC", "-Xshare:auto")
}

dependencies {
    implementation(project(":core"))
    testImplementation(libs.kotlin.test.junit)
}
