package com.camtransfer.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.camtransfer.model.CameraFile
import com.camtransfer.service.CameraService
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class BrowseViewModel : ViewModel() {

    private val _files = MutableStateFlow<List<CameraFile>>(emptyList())
    val files: StateFlow<List<CameraFile>> = _files.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _selectedHandles = MutableStateFlow<Set<Int>>(emptySet())
    val selectedHandles: StateFlow<Set<Int>> = _selectedHandles.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    fun loadFiles(cameraService: CameraService) {
        if (_isLoading.value) return
        _isLoading.value = true
        _error.value = null

        viewModelScope.launch {
            try {
                val fileList = cameraService.listFiles()
                _files.value = fileList
            } catch (e: Exception) {
                _error.value = e.message ?: "加载文件列表失败"
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun loadThumbnail(cameraService: CameraService, handle: Int) {
        viewModelScope.launch {
            try {
                val thumb = cameraService.getThumbnail(handle)
                _files.value = _files.value.map { file ->
                    if (file.info.handle == handle) file.copy(thumbnail = thumb) else file
                }
            } catch (_: Exception) {}
        }
    }

    fun toggleSelection(handle: Int) {
        val current = _selectedHandles.value.toMutableSet()
        if (handle in current) current.remove(handle) else current.add(handle)
        _selectedHandles.value = current
    }

    fun selectAll() {
        _selectedHandles.value = _files.value.map { it.info.handle }.toSet()
    }

    fun clearSelection() {
        _selectedHandles.value = emptySet()
    }

    fun getSelectedFiles(): List<CameraFile> {
        val selected = _selectedHandles.value
        return _files.value.filter { it.info.handle in selected }
    }
}
