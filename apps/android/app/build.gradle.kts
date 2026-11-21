plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "app.nonanona"
    // Compose 1.12·lifecycle 2.11이 compileSdk 37 이상을 요구한다. AGP 9.3.1이 검증한 상한인 37.1을 쓴다.
    // 실행 동작은 targetSdk 36으로 그대로 둔다.
    compileSdk {
        version = release(37) { minorApiLevel = 1 }
    }

    defaultConfig {
        // 임시 식별자다. 출시 전 스토어 등록과 함께 확정한다.
        applicationId = "app.nonanona"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            // 서명 설정은 출시 준비에서 정한다. 로컬 release 빌드는 서명하지 않는다.
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures { compose = true }

    lint {
        warningsAsErrors = false
        abortOnError = true
        checkReleaseBuilds = true
    }
}

dependencies {
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.navigation3.ui)
    debugImplementation(libs.compose.ui.tooling)

    testImplementation(libs.junit)
}
