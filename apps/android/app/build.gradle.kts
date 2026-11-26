import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

// 로컬 debug 모드. scripts/local-backend.py가 만든 local-backend.properties(gitignore)가 있을 때만 값이 채워진다.
// release 빌드에는 이 필드가 생기지 않는다.
val localBackend =
    Properties().apply {
        val file = rootProject.file("local-backend.properties")
        if (file.isFile) file.reader(Charsets.UTF_8).use { load(it) }
    }

// -Pnonanona.backend=test로 설정 파일이 있어도 테스트 구현체로 빌드한다(테스트 모드 E2E).
val localEnabled = localBackend.getProperty("backend") == "local" && providers.gradleProperty("nonanona.backend").orNull != "test"

fun localValue(name: String): String = "\"" + (if (localEnabled) localBackend.getProperty(name).orEmpty() else "") + "\""

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
        debug {
            buildConfigField("String", "LOCAL_SUPABASE_URL", localValue("supabaseUrl"))
            buildConfigField("String", "LOCAL_PUBLISHABLE_KEY", localValue("publishableKey"))
            buildConfigField("String", "LOCAL_TEST_EMAIL", localValue("testEmail"))
            buildConfigField("String", "LOCAL_TEST_PASSWORD", localValue("testPassword"))
            // 가상 방장 계정. files/debug-processing.properties의 localAccount=host로 고른다(기본은 가상 회원).
            buildConfigField("String", "LOCAL_HOST_EMAIL", localValue("hostEmail"))
            buildConfigField("String", "LOCAL_HOST_PASSWORD", localValue("hostPassword"))
        }
        release {
            // 서명 설정은 출시 준비에서 정한다. 로컬 release 빌드는 서명하지 않는다.
            isMinifyEnabled = false
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

    lint {
        warningsAsErrors = false
        abortOnError = true
        checkReleaseBuilds = true
    }
}

// 공통 시험표만 바뀌어도 단위 시험을 다시 실행한다.
tasks.withType<Test>().configureEach {
    inputs
        .file(layout.projectDirectory.file("../../fixtures/masking/common-policy.json"))
        .withPathSensitivity(PathSensitivity.RELATIVE)
    inputs
        .dir(layout.projectDirectory.dir("../../fixtures/korean"))
        .withPathSensitivity(PathSensitivity.RELATIVE)
}

dependencies {
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3.adaptive)
    implementation(libs.compose.material3.adaptive.layout)
    implementation(libs.compose.material3.adaptive.navigation3)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.navigation3.ui)
    implementation(libs.mlkit.text.japanese)
    implementation(libs.mlkit.text.korean)
    debugImplementation(libs.compose.ui.tooling)

    testImplementation(libs.junit)
    testImplementation(libs.org.json)
}
