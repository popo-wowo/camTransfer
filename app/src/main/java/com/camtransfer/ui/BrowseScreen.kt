package com.camtransfer.ui

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import com.camtransfer.model.CameraFile
import com.camtransfer.service.CameraService
import com.camtransfer.viewmodel.BrowseViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BrowseScreen(
    viewModel: BrowseViewModel,
    cameraService: CameraService,
    onTransfer: (List<CameraFile>) -> Unit,
    onDisconnect: () -> Unit,
) {
    val files by viewModel.files.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val selectedHandles by viewModel.selectedHandles.collectAsState()
    val error by viewModel.error.collectAsState()

    LaunchedEffect(Unit) {
        if (files.isEmpty()) viewModel.loadFiles(cameraService)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    if (selectedHandles.isNotEmpty()) {
                        Text("已选 ${selectedHandles.size} 项")
                    } else {
                        Text("相机文件 (${files.size})")
                    }
                },
                actions = {
                    if (selectedHandles.isNotEmpty()) {
                        TextButton(onClick = { viewModel.clearSelection() }) { Text("取消") }
                        TextButton(onClick = { viewModel.selectAll() }) { Text("全选") }
                        Button(onClick = { onTransfer(viewModel.getSelectedFiles()) }) {
                            Text("传输")
                        }
                    } else {
                        TextButton(onClick = { onDisconnect() }) { Text("断开") }
                    }
                }
            )
        }
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                isLoading -> {
                    CircularProgressIndicator(Modifier.align(Alignment.Center))
                }
                error != null -> {
                    Column(Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(error!!, color = MaterialTheme.colorScheme.error)
                        Spacer(Modifier.height(8.dp))
                        Button(onClick = { viewModel.loadFiles(cameraService) }) { Text("重试") }
                    }
                }
                files.isEmpty() -> {
                    Text("相机中没有文件", Modifier.align(Alignment.Center))
                }
                else -> {
                    LazyVerticalGrid(
                        columns = GridCells.Fixed(3),
                        contentPadding = PaddingValues(4.dp),
                    ) {
                        items(files, key = { it.info.handle }) { file ->
                            FileGridItem(
                                file = file,
                                isSelected = file.info.handle in selectedHandles,
                                onClick = { viewModel.toggleSelection(file.info.handle) },
                                onVisible = { viewModel.loadThumbnail(cameraService, file.info.handle) },
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun FileGridItem(
    file: CameraFile,
    isSelected: Boolean,
    onClick: () -> Unit,
    onVisible: () -> Unit,
) {
    LaunchedEffect(file.info.handle) {
        if (file.thumbnail == null) onVisible()
    }

    Box(
        modifier = Modifier
            .aspectRatio(1f)
            .padding(2.dp)
            .clickable { onClick() }
    ) {
        val thumb = file.thumbnail
        if (thumb != null) {
            val bitmap = remember(thumb) {
                BitmapFactory.decodeByteArray(thumb, 0, thumb.size)
            }
            if (bitmap != null) {
                Image(
                    bitmap = bitmap.asImageBitmap(),
                    contentDescription = file.info.filename,
                    modifier = Modifier.fillMaxSize(),
                    contentScale = ContentScale.Crop,
                )
            } else {
                PlaceholderBox(file)
            }
        } else {
            PlaceholderBox(file)
        }

        if (isSelected) {
            Box(
                Modifier.fillMaxSize().background(Color(0x4400AAFF))
            )
            Checkbox(
                checked = true,
                onCheckedChange = null,
                modifier = Modifier.align(Alignment.TopEnd).size(24.dp),
            )
        }

        Text(
            file.info.formatLabel,
            modifier = Modifier.align(Alignment.BottomStart).padding(4.dp),
            style = MaterialTheme.typography.labelSmall,
            color = Color.White,
        )
    }
}

@Composable
private fun PlaceholderBox(file: CameraFile) {
    Box(
        Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surfaceVariant),
        contentAlignment = Alignment.Center,
    ) {
        Text(file.info.formatLabel, style = MaterialTheme.typography.bodySmall)
    }
}
