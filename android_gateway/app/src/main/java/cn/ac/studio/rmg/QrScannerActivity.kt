package cn.ac.studio.rmg

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.MenuItem
import android.view.View
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.CameraInfoUnavailableException
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import com.google.android.material.button.MaterialButton
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class QrScannerActivity : AppCompatActivity() {
    companion object {
        const val EXTRA_RESULT = "cn.ac.studio.rmg.extra.QR_RESULT"
    }

    private lateinit var previewView: PreviewView
    private lateinit var stateCard: View
    private lateinit var stateTitle: TextView
    private lateinit var stateMessage: TextView
    private lateinit var stateAction: MaterialButton
    private lateinit var scanner: BarcodeScanner
    private lateinit var cameraExecutor: ExecutorService

    private var cameraProvider: ProcessCameraProvider? = null
    private var cameraBindingRequested = false
    private var cameraPermissionRequested = false
    private val completed = AtomicBoolean(false)

    private val cameraPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) {
                startCamera()
            } else {
                val permanentlyDenied =
                    cameraPermissionRequested && !shouldShowRequestPermissionRationale(Manifest.permission.CAMERA)
                showPermissionState(openSettings = permanentlyDenied)
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        GatewayTheme.apply(this)
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_qr_scanner)
        GatewayTheme.applyEdgeToEdgePadding(findViewById(R.id.appBar), includeTop = true, includeBottom = false)
        GatewayTheme.applyEdgeToEdgePadding(findViewById(R.id.bottomPanel), includeTop = false, includeBottom = true)
        setSupportActionBar(findViewById(R.id.toolbar))
        supportActionBar?.setDisplayHomeAsUpEnabled(true)
        title = getString(R.string.title_qr_scanner)

        previewView = findViewById(R.id.previewView)
        stateCard = findViewById(R.id.scannerStateCard)
        stateTitle = findViewById(R.id.txtScannerStateTitle)
        stateMessage = findViewById(R.id.txtScannerStateMessage)
        stateAction = findViewById(R.id.btnScannerStateAction)
        scanner = BarcodeScanning.getClient(
            BarcodeScannerOptions.Builder()
                .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                .build()
        )
        cameraExecutor = Executors.newSingleThreadExecutor()

        ensureCameraPermission(autoRequest = true)
    }

    override fun onResume() {
        super.onResume()
        if (::previewView.isInitialized && hasCameraPermission() && cameraProvider == null && !completed.get()) {
            startCamera()
        }
    }

    override fun onDestroy() {
        cameraProvider?.unbindAll()
        if (::scanner.isInitialized) {
            scanner.close()
        }
        if (::cameraExecutor.isInitialized) {
            cameraExecutor.shutdown()
        }
        super.onDestroy()
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean {
        if (item.itemId == android.R.id.home) {
            finish()
            return true
        }
        return super.onOptionsItemSelected(item)
    }

    private fun ensureCameraPermission(autoRequest: Boolean) {
        if (hasCameraPermission()) {
            startCamera()
            return
        }
        showPermissionState(openSettings = false)
        if (autoRequest) {
            requestCameraPermission()
        }
    }

    private fun hasCameraPermission(): Boolean {
        return ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun requestCameraPermission() {
        cameraPermissionRequested = true
        cameraPermissionLauncher.launch(Manifest.permission.CAMERA)
    }

    private fun startCamera() {
        if (cameraBindingRequested || completed.get()) return
        if (!hasCameraPermission()) {
            showPermissionState(openSettings = false)
            return
        }
        cameraBindingRequested = true

        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener(
            {
                try {
                    val provider = cameraProviderFuture.get()
                    cameraProvider = provider
                    val cameraSelector = selectCamera(provider)
                    if (cameraSelector == null) {
                        cameraBindingRequested = false
                        showBlockingState(
                            title = getString(R.string.scanner_camera_error_title),
                            message = getString(R.string.scanner_no_camera_message),
                            actionText = null
                        )
                        return@addListener
                    }

                    val preview = Preview.Builder().build().also {
                        it.setSurfaceProvider(previewView.surfaceProvider)
                    }
                    val analysis = ImageAnalysis.Builder()
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .build()
                        .also {
                            it.setAnalyzer(cameraExecutor, ::analyzeImage)
                        }

                    provider.unbindAll()
                    provider.bindToLifecycle(this, cameraSelector, preview, analysis)
                    hideBlockingState()
                } catch (e: Exception) {
                    cameraBindingRequested = false
                    showBlockingState(
                        title = getString(R.string.scanner_camera_error_title),
                        message = getString(R.string.scanner_camera_error_message, e.localizedMessage ?: e.javaClass.simpleName),
                        actionText = null
                    )
                }
            },
            ContextCompat.getMainExecutor(this)
        )
    }

    private fun selectCamera(provider: ProcessCameraProvider): CameraSelector? {
        return try {
            when {
                provider.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA) -> CameraSelector.DEFAULT_BACK_CAMERA
                provider.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA) -> CameraSelector.DEFAULT_FRONT_CAMERA
                else -> null
            }
        } catch (_: CameraInfoUnavailableException) {
            null
        }
    }

    @ExperimentalGetImage
    private fun analyzeImage(imageProxy: ImageProxy) {
        if (completed.get()) {
            imageProxy.close()
            return
        }

        val mediaImage = imageProxy.image
        if (mediaImage == null) {
            imageProxy.close()
            return
        }

        val image = InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)
        scanner.process(image)
            .addOnSuccessListener { barcodes ->
                val value = barcodes.asSequence()
                    .mapNotNull { it.rawValue?.trim() }
                    .firstOrNull { it.isNotEmpty() }
                if (value != null) {
                    finishWithResult(value)
                }
            }
            .addOnCompleteListener {
                imageProxy.close()
            }
    }

    private fun finishWithResult(value: String) {
        if (!completed.compareAndSet(false, true)) return
        runOnUiThread {
            cameraProvider?.unbindAll()
            setResult(Activity.RESULT_OK, Intent().putExtra(EXTRA_RESULT, value))
            finish()
        }
    }

    private fun showPermissionState(openSettings: Boolean) {
        val actionText = if (openSettings) {
            getString(R.string.action_open_app_settings)
        } else {
            getString(R.string.action_grant_camera)
        }
        showBlockingState(
            title = getString(R.string.scanner_permission_title),
            message = getString(R.string.scanner_permission_message),
            actionText = actionText
        ) {
            if (openSettings) {
                PermissionAndRoleHelper.openAppDetailsSettings(this)
            } else {
                requestCameraPermission()
            }
        }
    }

    private fun showBlockingState(
        title: String,
        message: String,
        actionText: String?,
        action: (() -> Unit)? = null
    ) {
        stateTitle.text = title
        stateMessage.text = message
        stateAction.visibility = if (actionText == null || action == null) View.GONE else View.VISIBLE
        if (actionText != null && action != null) {
            stateAction.text = actionText
            stateAction.setOnClickListener { action() }
        } else {
            stateAction.setOnClickListener(null)
        }
        stateCard.visibility = View.VISIBLE
    }

    private fun hideBlockingState() {
        stateCard.visibility = View.GONE
    }
}
