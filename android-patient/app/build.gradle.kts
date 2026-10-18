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

dependencies {
    // 纯 JVM 单元测试（不跑 Android 运行时）：契约解析是"服务端字段 ↔ 客户端必填"的接缝，
    // 2026-10-18 有 3 个真缺陷都出在这里（医生队列缺 schedule_id、病历缺 version、
    // 乐观锁字段名写成 expected_version），见 docs/审查-同事提交-2026-10-18.md。
    testImplementation("junit:junit:4.13.2")
    // Android 自带的 org.json 在 JVM 单测里是 stub（调用即 RuntimeException），
    // 所以显式引入同 API 的实现，让 ContractParser 能在测试里真解析金样本。
    testImplementation("org.json:json:20240303")
}