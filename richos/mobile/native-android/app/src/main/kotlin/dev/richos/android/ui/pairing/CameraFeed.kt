package dev.richos.android.ui.pairing

import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.CameraState
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import dev.richos.android.ui.model.ScannerCamera
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The live camera behind the scanner: CameraX's preview, and every frame read for a QR code on
 * the phone ([QrDecoder]). T3's design for the iPhone (adoption ledger P1), in CameraX's terms: the
 * camera follows the screen's lifecycle, so it stops when the app leaves the front and starts again
 * when it returns, and it is released the moment the scanner closes. It reports [onStatus]:
 * opening, showing, or not available (no camera, another app holding it, a device policy).
 *
 * [onCode] receives each code read; it answers whether the code was taken, after which no more
 * frames are read.
 */
@Composable
fun CameraFeed(onStatus: (ScannerCamera) -> Unit, onCode: (String) -> Boolean) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val status by rememberUpdatedState(onStatus)
    val code by rememberUpdatedState(onCode)
    val view = remember {
        PreviewView(context).apply {
            scaleType = PreviewView.ScaleType.FILL_CENTER
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        }
    }
    DisposableEffect(owner) {
        val main = ContextCompat.getMainExecutor(context)
        val frames = Executors.newSingleThreadExecutor()
        val taken = AtomicBoolean(false)
        val preview = Preview.Builder().build()
        val analysis = ImageAnalysis.Builder()
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setResolutionSelector(
                ResolutionSelector.Builder()
                    .setResolutionStrategy(ResolutionStrategy(Size(1280, 720), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER))
                    .build(),
            )
            .build()
        analysis.setAnalyzer(frames, QrAnalyzer { text ->
            if (!taken.get()) main.execute { if (!taken.get() && code(text)) taken.set(true) }
        })
        var provider: ProcessCameraProvider? = null
        var disposed = false
        status(ScannerCamera.CHECKING)
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (disposed) return@addListener
            try {
                val p = future.get().also { provider = it }
                val selector = when {
                    p.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA) -> CameraSelector.DEFAULT_BACK_CAMERA
                    // A tablet or a laptop running Android may have only a front camera.
                    p.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA) -> CameraSelector.DEFAULT_FRONT_CAMERA
                    else -> null
                }
                if (selector == null) {
                    status(ScannerCamera.UNAVAILABLE)
                    return@addListener
                }
                preview.setSurfaceProvider(view.surfaceProvider)
                val camera = p.bindToLifecycle(owner, selector, preview, analysis)
                camera.cameraInfo.cameraState.observe(owner) { s ->
                    when {
                        s.type == CameraState.Type.OPEN -> status(ScannerCamera.READY)
                        // Closed with an error (in use elsewhere, disabled by policy, a fault): say so.
                        s.error != null && (s.type == CameraState.Type.CLOSED || s.type == CameraState.Type.PENDING_OPEN) ->
                            status(ScannerCamera.UNAVAILABLE)
                    }
                }
            } catch (e: Exception) {
                // CameraX found no usable camera or could not bind one (IllegalArgumentException,
                // IllegalStateException, CameraUnavailableException inside an ExecutionException).
                status(ScannerCamera.UNAVAILABLE)
            }
        }, main)
        onDispose {
            disposed = true
            provider?.unbind(preview, analysis)
            analysis.clearAnalyzer()
            frames.shutdown()
        }
    }
    AndroidView(factory = { view }, modifier = Modifier.fillMaxSize().clearAndSetSemantics { })
}

/**
 * One frame's luminance (the Y plane of YUV_420_888) to [QrDecoder]. Frames arrive on one
 * background thread; the newest replaces any not yet read (STRATEGY_KEEP_ONLY_LATEST).
 */
internal class QrAnalyzer(private val found: (String) -> Unit) : ImageAnalysis.Analyzer {
    private var buffer = ByteArray(0)

    override fun analyze(image: ImageProxy) {
        image.use {
            val plane = it.planes.firstOrNull() ?: return
            val stride = plane.rowStride
            val size = stride * it.height
            if (buffer.size != size) buffer = ByteArray(size)
            val data = plane.buffer
            data.rewind()
            // The last row may end at the picture's width rather than the full stride.
            data.get(buffer, 0, minOf(size, data.remaining()))
            QrDecoder.decodeLuminance(buffer, stride, it.height, it.width, it.height)?.let(found)
        }
    }
}
