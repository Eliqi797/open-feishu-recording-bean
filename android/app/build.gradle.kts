import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val personalDefaults = Properties().apply {
    val source = rootProject.file("personal-defaults.properties")
    if (source.isFile) source.inputStream().use { load(it) }
}
fun personalBase64(name: String): String = personalDefaults.getProperty(name, "").also {
    require(it.matches(Regex("[A-Za-z0-9+/=]*"))) { "Invalid local mobile defaults" }
}

android {
    namespace = "xyz.recordingbean.app"
    compileSdk = 36
    buildFeatures { buildConfig = true }
    defaultConfig {
        applicationId = "xyz.recordingbean.app"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("String", "PERSONAL_ORIGIN_BASE64", "\"${personalBase64("originBase64")}\"")
        buildConfigField("String", "PERSONAL_TOKEN_BASE64", "\"${personalBase64("tokenBase64")}\"")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}
