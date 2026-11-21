package app.nonanona

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.ViewModelProvider
import app.nonanona.design.NonanonaTheme

class MainActivity : ComponentActivity() {
    private val viewModel by lazy {
        val graph = (application as NonanonaApplication).graph
        ViewModelProvider(this, AppViewModel.factory(graph))[AppViewModel::class.java]
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) viewModel.handle(intent)
        setContent { NonanonaTheme { NonanonaApp(viewModel) } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        viewModel.handle(intent)
    }
}
