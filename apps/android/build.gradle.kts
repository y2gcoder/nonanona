plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.compose) apply false
}

// 전이 의존성까지 gradle.lockfile에 고정한다. 갱신: ./gradlew :app:dependencies --write-locks
allprojects { dependencyLocking { lockAllConfigurations() } }
