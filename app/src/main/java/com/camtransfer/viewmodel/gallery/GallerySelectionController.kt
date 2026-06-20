package com.camtransfer.viewmodel.gallery

import com.camtransfer.model.CameraFile
import com.camtransfer.model.TransferState
import com.camtransfer.ui.GalleryDownloadUiPolicy
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

class GallerySelectionController {
    private val _selectedHandles = MutableStateFlow<Set<Int>>(emptySet())
    val selectedHandles: StateFlow<Set<Int>> = _selectedHandles.asStateFlow()

    fun toggle(handle: Int) {
        val current = _selectedHandles.value.toMutableSet()
        if (handle in current) current.remove(handle) else current.add(handle)
        _selectedHandles.value = current
    }

    fun selectAll(files: List<CameraFile>) {
        _selectedHandles.value = files.map { it.info.handle }.toSet()
    }

    fun selectHandles(handles: Set<Int>) {
        _selectedHandles.value = handles
    }

    fun clear() {
        _selectedHandles.value = emptySet()
    }

    fun selectedFiles(
        files: List<CameraFile>,
        downloadStates: Map<Int, TransferState?> = emptyMap(),
    ): List<CameraFile> {
        val selected = _selectedHandles.value
        return files.filter { file ->
            file.info.handle in selected &&
                GalleryDownloadUiPolicy.canSelect(downloadStates[file.info.handle])
        }
    }
}
