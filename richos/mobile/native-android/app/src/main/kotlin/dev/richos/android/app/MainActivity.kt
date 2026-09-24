package dev.richos.android.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.ReportDrawnWhen
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import dev.richos.android.ui.composer.DraftLink
import dev.richos.android.ui.composer.LocalDraftLink
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LifecycleResumeEffect
import dev.richos.android.ui.model.ScannerCamera
import dev.richos.android.ui.pairing.CameraFeed
import dev.richos.android.ui.pairing.pairingEntry
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
import androidx.core.view.WindowCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.richos.android.core.AppState
import dev.richos.android.core.Theme
import dev.richos.android.design.phoneTheme
import dev.richos.android.platform.NotificationTaps
import dev.richos.android.platform.StagedPhotos
import dev.richos.android.ui.attach.LocalPhotoPixels
import androidx.lifecycle.lifecycleScope
import dev.richos.android.ui.RichApp
import dev.richos.android.ui.model.ScreenModel
import dev.richos.android.ui.toAction

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
            // Useful content, for the launch measurement (PRD 2026-09-24 §7, J1): the platform's own
            // "fully drawn" launch event fires on the first frame drawn after the saved state is read,
            // i.e. the conversation (or, on a first install, pairing) with its composer, never the
            // bare ground below. One report per activity; it observes nothing after that.
            ReportDrawnWhen { state != null }
            // The app follows the phone's light/dark setting (the CEO, 2026-09-24: "Follow the
            // phone"); the system bar icons with it.
            val theme = phoneTheme()
            val dark = theme == Theme.DARK
            // Set on the window directly: re-calling enableEdgeToEdge from a composition effect did
            // not change the window's appearance (measured on the API 34 emulator: no
            // LIGHT_STATUS_BARS flag, white icons on the light ground).
            LaunchedEffect(dark) {
                WindowCompat.getInsetsController(window, window.decorView).apply {
                    isAppearanceLightStatusBars = !dark
                    isAppearanceLightNavigationBars = !dark
                }
            }
            val refusal by store.lastRefusal.collectAsStateWithLifecycle()
            // Pairing's platform half: the camera question, the scanner, the link sheet's answer.
            val entry = remember { pairingEntry }
            val pairing by entry.states.collectAsStateWithLifecycle()
            val askCamera = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { entry.cameraAnswer(it) }
            // Back from Settings with the camera now allowed: straight to the scanner.
            LifecycleResumeEffect(entry) {
                entry.resumed(cameraGranted())
                onPauseOrDispose { }
            }
            val current = state
            if (current != null) {
                val model = ScreenModel(app = current.copy(theme = theme), refusal = refusal, pairingSurface = pairing.surface, scannerCamera = pairing.camera)
                BackHandler(enabled = entry.ownsBack(current)) { entry.back(current) }
                // The message field's own line to core's draft, so typing never waits on core.
                val drafts = remember(store) {
                    object : DraftLink {
                        override fun latest() = store.committedDraft
                        override fun write(text: String, done: () -> Unit) = store.composeDraft(text, done)
                    }
                }
                // The photos this phone still holds, drawn with their real pixels (decoded once, on demand).
                val photos = remember { StagedPhotos(AppPorts.stagedDir(this@MainActivity), lifecycleScope) }
                CompositionLocalProvider(LocalDraftLink provides drafts, LocalPhotoPixels provides photos::pixels) {
                    RichApp(
                        model,
                        onEvent = { e ->
                            val handled = entry.handle(
                                e,
                                hasCamera = { packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY) },
                                cameraGranted = ::cameraGranted,
                                requestCamera = { askCamera.launch(Manifest.permission.CAMERA) },
                            )
                            if (!handled) e.toAction()?.let(store::dispatch)
                        },
                        // No camera to open (none on the phone, or it failed): nothing is left holding it.
                        camera = if (pairing.camera == ScannerCamera.UNAVAILABLE) null else ({ CameraFeed(onStatus = entry::cameraStatus, onCode = entry::scanned) }),
                    )
                }
            } else {
                // Until the saved state is read (a few milliseconds): the ground, nothing else.
                AppRoot(null, theme, problem = refusal)
            }
        }
        // A tapped reply notification opens that reply (platform/NotificationTaps.kt).
        if (savedInstanceState == null) NotificationTaps.handle(intent, store, (application as RichApplication).appScope)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        NotificationTaps.handle(intent, richStore, (application as RichApplication).appScope)
    }
}

private fun ComponentActivity.cameraGranted(): Boolean =
    ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

/**
 * PLACEHOLDER ROOT, owned by A1 until the screens stream (A2, the `ui/` and `design/` packages)
 * replaces its body with the round-12 screens. It shows only the draft, so the development
 * loop can see a bridge action reach the screen. Colors are the ruled ink on the ruled ground
 * of each theme (design/system/tokens.css §14/§15): 14.55:1 dark, 14.90:1 light, 18 sp.
 */
@Composable
fun AppRoot(state: AppState?, theme: Theme, problem: String? = null) {
    val dark = theme == Theme.DARK
    val ground = if (dark) Color(0xFF0C1322) else Color(0xFFEAE6DD)
    val ink = if (dark) Color(0xFFDFE4EE) else Color(0xFF0C1322)
    Box(Modifier.fillMaxSize().background(ground).safeDrawingPadding(), contentAlignment = Alignment.Center) {
        if (problem != null) {
            BasicText(problem, Modifier.padding(24.dp), style = TextStyle(color = ink, fontSize = 18.sp))
        } else if (state != null) {
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
