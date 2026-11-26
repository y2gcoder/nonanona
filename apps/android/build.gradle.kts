// 플러그인 클래스패스(AGP, Kotlin Compose 플러그인과 그 전이 의존성)도 buildscript-gradle.lockfile에 고정한다.
buildscript { configurations.classpath { resolutionStrategy.activateDependencyLocking() } }

plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.compose) apply false
}

// 전이 의존성까지 gradle.lockfile에 고정한다. 갱신: ./gradlew buildEnvironment :app:dependencies --write-locks
allprojects { dependencyLocking { lockAllConfigurations() } }
