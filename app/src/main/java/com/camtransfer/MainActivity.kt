package com.camtransfer

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import com.camtransfer.ui.BrowseScreen
import com.camtransfer.ui.ConnectScreen
import com.camtransfer.ui.TransferScreen
import com.camtransfer.viewmodel.BrowseViewModel
import com.camtransfer.viewmodel.ConnectionViewModel
import com.camtransfer.viewmodel.TransferViewModel

class MainActivity : ComponentActivity() {

    private val requiredPermissions = arrayOf(
        Manifest.permission.BLUETOOTH_SCAN,
        Manifest.permission.BLUETOOTH_CONNECT,
        Manifest.permission.ACCESS_FINE_LOCATION,
        Manifest.permission.READ_MEDIA_IMAGES,
        Manifest.permission.READ_MEDIA_VIDEO,
    )

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) {}

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val missing = requiredPermissions.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isNotEmpty()) {
            permissionLauncher.launch(missing.toTypedArray())
        }

        setContent {
            MaterialTheme {
                Surface(Modifier.fillMaxSize()) {
                    CamTransferApp()
                }
            }
        }
    }
}

enum class Screen { CONNECT, BROWSE, TRANSFER }

@Composable
fun CamTransferApp() {
    val connectionVM: ConnectionViewModel = viewModel()
    val browseVM: BrowseViewModel = viewModel()
    val transferVM: TransferViewModel = viewModel()

    var currentScreen by remember { mutableStateOf(Screen.CONNECT) }

    when (currentScreen) {
        Screen.CONNECT -> ConnectScreen(
            viewModel = connectionVM,
            onConnected = { currentScreen = Screen.BROWSE },
        )
        Screen.BROWSE -> BrowseScreen(
            viewModel = browseVM,
            cameraService = connectionVM.cameraService,
            onTransfer = { files ->
                transferVM.init(connectionVM.cameraService)
                transferVM.startTransfer(files)
                currentScreen = Screen.TRANSFER
            },
            onDisconnect = {
                connectionVM.disconnect()
                currentScreen = Screen.CONNECT
            },
        )
        Screen.TRANSFER -> TransferScreen(
            viewModel = transferVM,
            onBack = { currentScreen = Screen.BROWSE },
        )
    }
}
