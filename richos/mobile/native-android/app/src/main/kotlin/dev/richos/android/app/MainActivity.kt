package dev.richos.android.app

import android.os.Bundle
import android.graphics.Color as AndroidColor
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.richos.android.core.AppState
import dev.richos.android.core.Theme

/** The single activity (build plan §3.3). Edge to edge; Compose draws everything. */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(AndroidColor.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(AndroidColor.TRANSPARENT),
        )
        super.onCreate(savedInstanceState)
        val store = richStore
        setContent {
            val state by store.states.collectAsStateWithLifecycle()
            // System bar icons follow the APP's theme, not the phone's: dark is the default
            // whatever the phone says (ceo-decisions §15), so light icons unless light is chosen.
            val dark = state?.theme != Theme.LIGHT
            LaunchedEffect(dark) {
                val bars = if (dark) {
                    SystemBarStyle.dark(AndroidColor.TRANSPARENT)
                } else {
                    SystemBarStyle.light(AndroidColor.TRANSPARENT, AndroidColor.TRANSPARENT)
                }
                enableEdgeToEdge(statusBarStyle = bars, navigationBarStyle = bars)
            }
            AppRoot(state)
        }
    }
}

/**
 * PLACEHOLDER ROOT, owned by A1 until the screens stream (A2, the `ui/` and `design/` packages)
 * replaces its body with the round-12 screens. It shows only the draft, so the development
 * loop can see a bridge action reach the screen. Colors are the ruled ink on the ruled ground
 * of each theme (design/system/tokens.css §14/§15): 14.55:1 dark, 14.90:1 light, 18 sp.
 */
@Composable
fun AppRoot(state: AppState?) {
    val dark = state?.theme != Theme.LIGHT
    val ground = if (dark) Color(0xFF0C1322) else Color(0xFFEAE6DD)
    val ink = if (dark) Color(0xFFDFE4EE) else Color(0xFF0C1322)
    Box(Modifier.fillMaxSize().background(ground).safeDrawingPadding(), contentAlignment = Alignment.Center) {
        if (state != null) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                val text = state.draft.ifEmpty { "Message Rich" }
                BasicText(
                    text = text,
                    modifier = Modifier.padding(24.dp).semantics { contentDescription = "draft" },
                    style = TextStyle(color = ink, fontSize = 18.sp),
                )
            }
        }
    }
}
