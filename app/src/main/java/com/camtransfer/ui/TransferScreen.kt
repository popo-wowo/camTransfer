package com.camtransfer.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.camtransfer.model.TransferItem
import com.camtransfer.model.TransferState
import com.camtransfer.viewmodel.TransferViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TransferScreen(
    viewModel: TransferViewModel,
    onBack: () -> Unit,
) {
    val items by (viewModel.items ?: return).collectAsState()
    val isTransferring by (viewModel.isTransferring ?: return).collectAsState()

    val doneCount = items.count { it.state == TransferState.DONE }
    val totalCount = items.size

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("传输 ($doneCount/$totalCount)") },
                navigationIcon = {
                    TextButton(onClick = onBack) { Text("返回") }
                },
                actions = {
                    if (!isTransferring && items.any { it.state == TransferState.DONE }) {
                        TextButton(onClick = { viewModel.clearCompleted() }) { Text("清除已完成") }
                    }
                }
            )
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            items(items, key = { it.file.info.handle }) { item ->
                TransferItemRow(item)
            }
        }
    }
}

@Composable
private fun TransferItemRow(item: TransferItem) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(item.file.info.filename, style = MaterialTheme.typography.bodyMedium)
                    Text(
                        formatSize(item.file.info.compressedSize) + " · " + item.file.info.formatLabel,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Text(
                    when (item.state) {
                        TransferState.PENDING -> "等待中"
                        TransferState.DOWNLOADING -> "下载中"
                        TransferState.SAVING -> "保存中"
                        TransferState.DONE -> "完成"
                        TransferState.ERROR -> "失败"
                    },
                    style = MaterialTheme.typography.labelMedium,
                    color = when (item.state) {
                        TransferState.DONE -> MaterialTheme.colorScheme.primary
                        TransferState.ERROR -> MaterialTheme.colorScheme.error
                        else -> MaterialTheme.colorScheme.onSurfaceVariant
                    }
                )
            }
            if (item.state == TransferState.DOWNLOADING || item.state == TransferState.SAVING) {
                Spacer(Modifier.height(8.dp))
                LinearProgressIndicator(
                    progress = { item.progress },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            if (item.error != null) {
                Spacer(Modifier.height(4.dp))
                Text(item.error, style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error)
            }
        }
    }
}

private fun formatSize(bytes: Int): String {
    if (bytes < 1024) return "$bytes B"
    val kb = bytes / 1024.0
    if (kb < 1024) return "%.1f KB".format(kb)
    val mb = kb / 1024.0
    return "%.1f MB".format(mb)
}
