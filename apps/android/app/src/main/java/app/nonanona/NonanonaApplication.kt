package app.nonanona

import android.app.Application

class NonanonaApplication : Application() {
    val graph: AppGraph by lazy { AppGraph(this) }
}
