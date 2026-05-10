package com.camtransfer.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.camtransfer.viewmodel.ConnectionState
import com.camtransfer.viewmodel.ConnectionViewModel

@Composable
fun ConnectScreen(
    viewModel: ConnectionViewModel,
    onConnected: () -> Unit,
) {
    val state by viewModel.state.collectAsState()
    val statusText by viewModel.statusText.collectAsState()
    val error by viewModel.error.collectAsState()

    LaunchedEffect(state) {
        if (state == ConnectionState.CONNECTED) onConnected()
    }

    Column(
        modifier = Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text("CamTransfer", style = MaterialTheme.typography.headlineLarge)
        Spacer(Modifier.height(8.dp))
        Text("快速传输你的相机照片", style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(48.dp))

        when (state) {
            ConnectionState.IDLE, ConnectionState.ERROR -> {
                Button(
                    onClick = { viewModel.connect() },
                    modifier = Modifier.fillMaxWidth().height(56.dp),
                ) {
                    Text("连接相机")
                }
                if (error != null) {
                    Spacer(Modifier.height(16.dp))
                    Text(error!!, color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodySmall)
                    Spacer(Modifier.height(8.dp))
                    TextButton(onClick = { viewModel.connect() }) {
                        Text("重试")
                    }
                }
            }
            else -> {
                CircularProgressIndicator()
                Spacer(Modifier.height(16.dp))
                Text(statusText, style = MaterialTheme.typography.bodyMedium)
            }
        }

        Spacer(Modifier.height(32.dp))
        Text(
            "请确保相机蓝牙已开启并进入配对模式",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
