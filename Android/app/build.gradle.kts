plugins {
    id("com.android.application")
}

android {
    namespace = "io.github.ckarefulon.netaccelerator"
    compileSdk = 35

    defaultConfig {
        applicationId = "io.github.ckarefulon.netaccelerator"
        minSdk = 26
        targetSdk = 35
        versionCode = 2
        versionName = "0.2.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
