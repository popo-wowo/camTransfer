package com.camtransfer.viewmodel.gallery

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.time.LocalDate

enum class GalleryBrowseMode {
    THUMBNAIL,
    HD_PREVIEW,
}

data class GalleryBrowseModeState(
    val mode: GalleryBrowseMode = GalleryBrowseMode.THUMBNAIL,
    val highDefinitionDate: LocalDate,
)

class GalleryBrowseModeController(
    private val todayProvider: () -> LocalDate = { LocalDate.now() },
) {
    private val _state = MutableStateFlow(
        GalleryBrowseModeState(
            mode = GalleryBrowseMode.THUMBNAIL,
            highDefinitionDate = todayProvider(),
        )
    )
    val state: StateFlow<GalleryBrowseModeState> = _state.asStateFlow()

    fun setMode(mode: GalleryBrowseMode) {
        _state.value = _state.value.copy(mode = mode)
    }

    fun setHighDefinitionDate(date: LocalDate) {
        _state.value = _state.value.copy(highDefinitionDate = date)
    }

    fun reset() {
        _state.value = GalleryBrowseModeState(
            mode = GalleryBrowseMode.THUMBNAIL,
            highDefinitionDate = todayProvider(),
        )
    }
}
