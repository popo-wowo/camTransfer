package com.camtransfer.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.camtransfer.model.CameraFile
import com.camtransfer.model.TransferState

@Composable
internal fun GalleryGrid(
    files: List<CameraFile>,
    columnCount: Int,
    gridState: LazyGridState,
    selectedHandles: Set<Int>,
    downloadStates: Map<Int, TransferState?>,
    isLoadingFullObjectInfo: Boolean,
    visibleGridHandleSet: Set<Int>,
    onColumnCountChange: (Int) -> Unit,
    onSelectionChange: (Set<Int>) -> Unit,
    onOpenFile: (CameraFile) -> Unit,
    onToggleSelection: (CameraFile) -> Unit,
    onVisible: (CameraFile) -> Unit,
) {
    LazyVerticalGrid(
        columns = GridCells.Fixed(columnCount),
        state = gridState,
        modifier = Modifier
            .fillMaxSize()
            .galleryColumnPinchResize(
                columnCount = columnCount,
                onColumnCountChange = onColumnCountChange,
            )
            .galleryDragSelection(
                gridState = gridState,
                files = files,
                selectedHandles = selectedHandles,
                downloadStates = downloadStates,
                onSelectionChange = onSelectionChange,
            ),
        contentPadding = PaddingValues(start = 12.dp, top = 8.dp, end = 12.dp, bottom = 96.dp),
        horizontalArrangement = Arrangement.spacedBy(GalleryGridSpacingPolicy.HORIZONTAL_DP.dp),
        verticalArrangement = Arrangement.spacedBy(GalleryGridSpacingPolicy.VERTICAL_DP.dp),
    ) {
        items(files, key = { it.info.handle }) { file ->
            val state = downloadStates[file.info.handle]
            GalleryGridItem(
                file = file,
                isSelected = file.info.handle in selectedHandles,
                downloadState = state,
                isLoadingFullObjectInfo = isLoadingFullObjectInfo,
                isItemVisible = file.info.handle in visibleGridHandleSet,
                onOpen = { onOpenFile(file) },
                onToggleSelection = {
                    if (GalleryDownloadUiPolicy.canSelect(state)) {
                        onToggleSelection(file)
                    }
                },
                onVisible = { onVisible(file) },
            )
        }
    }
}
