package com.camtransfer.viewmodel.gallery

import com.camtransfer.model.CameraFile
import com.camtransfer.model.ObjectInfo
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

class GalleryMetadataStore {
    private val _objectInfoByHandle = MutableStateFlow<Map<Int, ObjectInfo>>(emptyMap())
    val objectInfoByHandle: StateFlow<Map<Int, ObjectInfo>> = _objectInfoByHandle.asStateFlow()

    fun put(file: CameraFile) {
        _objectInfoByHandle.value = _objectInfoByHandle.value + (file.info.handle to file.info)
    }

    fun putAll(files: List<CameraFile>) {
        if (files.isEmpty()) return
        _objectInfoByHandle.value = _objectInfoByHandle.value + files.associate { it.info.handle to it.info }
    }

    fun snapshot(): Map<Int, ObjectInfo> =
        _objectInfoByHandle.value

    fun clear() {
        _objectInfoByHandle.value = emptyMap()
    }
}
