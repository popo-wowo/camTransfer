package com.camtransfer.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.camtransfer.model.CameraFile
import com.camtransfer.service.CameraFileSource
import com.camtransfer.viewmodel.BrowseViewModel

@Composable
fun HighDefinitionPreviewScreen(
    viewModel: BrowseViewModel,
    cameraSource: CameraFileSource,
    onOpenThumbnailGallery: () -> Unit,
    onDisconnect: () -> Unit,
) {
    val files by viewModel.files.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val previewImages by viewModel.previewImages.collectAsState()
    val loadedPreviewHandles by viewModel.loadedPreviewHandles.collectAsState()
    val loadingPreviewHandles by viewModel.loadingPreviewHandles.collectAsState()
    val error by viewModel.error.collectAsState()

    val mediaFiles = remember(files) {
        files.filterNot { it.info.isFolder }
    }
    val previewableFiles = remember(mediaFiles) {
        mediaFiles.filter { GalleryPreviewActionBarPolicy.canRequestHighDefinitionPreview(it) }
    }
    var sequentialIndex by remember(previewableFiles.map { it.info.handle }) { mutableIntStateOf(0) }
    var attemptedPreviewHandles by remember(previewableFiles.map { it.info.handle }) { mutableStateOf(emptySet<Int>()) }
    val loadedPreviewCount = remember(previewableFiles, loadedPreviewHandles) {
        previewableFiles.count { it.info.handle in loadedPreviewHandles }
    }

    LaunchedEffect(cameraSource) {
        viewModel.loadFilesIfNeeded(cameraSource)
    }
    LaunchedEffect(previewableFiles, loadedPreviewHandles, loadingPreviewHandles, sequentialIndex, attemptedPreviewHandles) {
        if (previewableFiles.isEmpty()) return@LaunchedEffect
        val next = previewableFiles.getOrNull(sequentialIndex) ?: return@LaunchedEffect
        val handle = next.info.handle
        when {
            handle in loadedPreviewHandles -> sequentialIndex += 1
            handle in loadingPreviewHandles -> Unit
            handle in attemptedPreviewHandles -> sequentialIndex += 1
            else -> {
                attemptedPreviewHandles = attemptedPreviewHandles + handle
                viewModel.loadPreviewImage(cameraSource, next)
            }
        }
    }

    BackHandler(onBack = onDisconnect)

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(CamTransferColors.Background)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Surface(
            modifier = Modifier.fillMaxWidth(),
            color = CamTransferColors.WarmFill,
            shape = androidx.compose.foundation.shape.RoundedCornerShape(20.dp),
            border = androidx.compose.foundation.BorderStroke(1.dp, CamTransferColors.Hairline),
        ) {
            Column(
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            "HD PREVIEW",
                            color = CamTransferColors.SecondaryInk,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Black,
                        )
                        Text(
                            "高清预览模式",
                            color = CamTransferColors.Ink,
                            fontSize = 22.sp,
                            fontWeight = FontWeight.Black,
                        )
                    }
                    TextButton(onClick = onDisconnect) {
                        Text("退出", color = CamTransferColors.Ink)
                    }
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    val statusText = when {
                        error != null -> error ?: "加载失败"
                        isLoading && mediaFiles.isEmpty() -> "正在读取相机照片"
                        previewableFiles.isEmpty() -> "当前没有可用的高清预览图片"
                        loadingPreviewHandles.isNotEmpty() ->
                            "高清预览加载中 $loadedPreviewCount / ${previewableFiles.size}"
                        sequentialIndex < previewableFiles.size ->
                            "准备继续加载 ${sequentialIndex + 1} / ${previewableFiles.size}"
                        else -> "高清预览已加载完成 ${previewableFiles.size} / ${previewableFiles.size}"
                    }
                    Text(
                        statusText,
                        modifier = Modifier.weight(1f),
                        color = CamTransferColors.SecondaryInk,
                        style = MaterialTheme.typography.bodySmall,
                    )
                    OutlinedButton(onClick = onOpenThumbnailGallery) {
                        Text("缩略图库", fontWeight = FontWeight.Bold)
                    }
                }
            }
        }

        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(
                items = mediaFiles,
                key = { it.info.handle },
            ) { file ->
                HighDefinitionPreviewCard(
                    file = file,
                    previewImage = previewImages[file.info.handle],
                    isLoading = file.info.handle in loadingPreviewHandles,
                    supported = GalleryPreviewActionBarPolicy.canRequestHighDefinitionPreview(file),
                    wasLoaded = file.info.handle in loadedPreviewHandles,
                )
            }
        }
    }
}

@Composable
private fun HighDefinitionPreviewCard(
    file: CameraFile,
    previewImage: ByteArray?,
    isLoading: Boolean,
    supported: Boolean,
    wasLoaded: Boolean,
) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = CamTransferColors.Card,
        shape = androidx.compose.foundation.shape.RoundedCornerShape(18.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, CamTransferColors.Hairline),
    ) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    file.info.formatLabel,
                    color = CamTransferColors.SecondaryInk,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Black,
                )
                Spacer(Modifier.weight(1f))
                Text(
                    when {
                        !supported -> "暂不支持"
                        previewImage != null -> "已加载"
                        wasLoaded -> "已加载"
                        isLoading -> "加载中"
                        else -> "等待中"
                    },
                    color = CamTransferColors.SecondaryInk,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                )
            }
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(280.dp)
                    .background(Color.Black, androidx.compose.foundation.shape.RoundedCornerShape(14.dp)),
                contentAlignment = Alignment.Center,
            ) {
                when {
                    !supported -> {
                        Text(
                            "当前格式暂不支持高清预览",
                            color = Color.White.copy(alpha = 0.8f),
                            fontWeight = FontWeight.Bold,
                        )
                    }
                    previewImage != null -> {
                        ZoomablePreviewImage(
                            file = file,
                            previewImage = previewImage,
                            manualRotationDegrees = 0,
                        )
                    }
                    isLoading -> {
                        CircularProgressIndicator(
                            modifier = Modifier.size(28.dp),
                            strokeWidth = 2.dp,
                            color = Color.White,
                        )
                    }
                    else -> {
                        Text(
                            if (wasLoaded) "已加载过，继续下滑可看后续" else "等待高清预览",
                            color = Color.White.copy(alpha = 0.72f),
                            fontWeight = FontWeight.Bold,
                        )
                    }
                }
            }
            Text(
                file.info.filename,
                color = CamTransferColors.Ink,
                fontWeight = FontWeight.Bold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
