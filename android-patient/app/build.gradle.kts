plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val configuredApiBaseUrl = providers.gradleProperty("apiBaseUrl").orElse(
    providers.environmentVariable("API_BASE_URL").orElse("")
).get()
val releaseKeystorePath = providers.environmentVariable("ANDROID_KEYSTORE_PATH").orElse("").get()
val releaseKeystorePassword = providers.environmentVariable("ANDROID_KEYSTORE_PASSWORD").orElse("").get()
val releaseKeyAlias = providers.environmentVariable("ANDROID_KEY_ALIAS").orElse("").get()
val releaseKeyPassword = providers.environmentVariable("ANDROID_KEY_PASSWORD").orElse("").get()

android {
    namespace = "com.smart.hospital.patient"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.smart.hospital.patient"
        minSdk = 26
        targetSdk = 35
        versionCode = 1000000
        versionName = "1.0.0"
        testInstrumentationRunner = "android.test.InstrumentationTestRunner"
    }

    signingConfigs {
        create("release") {
            if (releaseKeystorePath.isNotBlank()) {
                storeFile = file(releaseKeystorePath)
                storePassword = releaseKeystorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        debug {
            buildConfigField("String", "DEFAULT_BASE_URL", "\"${configuredApiBaseUrl.ifBlank { "http://127.0.0.1:8091" }}\"")
        }
        release {
            // Release generates BuildConfig.DEBUG=false; Android demo entry points
            // and repository demo branches must be guarded by that flag.
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            buildConfigField("String", "DEFAULT_BASE_URL", "\"${configuredApiBaseUrl.ifBlank { "https://example.invalid" }}\"")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    // AGP 8.x 起 BuildConfig 生成默认关闭，而本模块用 buildConfigField 注入 DEFAULT_BASE_URL，
    // 必须显式开启；否则配置阶段即失败：
    //   "Build Type 'debug' contains custom BuildConfig fields, but the feature is disabled."
    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

val checkReleaseConfig = tasks.register("checkReleaseConfig") {
    doLast {
        require(configuredApiBaseUrl.startsWith("https://")) {
            "Release requires -PapiBaseUrl=https://... or API_BASE_URL=https://..."
        }
        require(releaseKeystorePath.isNotBlank() && file(releaseKeystorePath).isFile) {
            "Release requires ANDROID_KEYSTORE_PATH pointing to a keystore outside the repository"
        }
        require(releaseKeystorePassword.isNotBlank() && releaseKeyAlias.isNotBlank() && releaseKeyPassword.isNotBlank()) {
            "Release requires ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS and ANDROID_KEY_PASSWORD"
        }
    }
}

tasks.matching { it.name == "preReleaseBuild" || it.name == "bundleRelease" }.configureEach {
    dependsOn(checkReleaseConfig)
}
