package com.camtransfer.viewmodel.gallery

import com.camtransfer.model.CameraFile
import com.camtransfer.model.ObjectInfo
import java.time.LocalDate
import java.time.format.DateTimeFormatter

object GalleryCatalogMergePolicy {
    fun displayFiles(
        catalogFiles: List<CameraFile>,
        objectInfoByHandle: Map<Int, ObjectInfo>,
    ): List<CameraFile> =
        catalogFiles.map { catalogFile ->
            val resolvedInfo = objectInfoByHandle[catalogFile.info.handle] ?: return@map catalogFile
            mergeResolvedMetadata(
                catalogFile = catalogFile,
                resolvedInfo = resolvedInfo,
            )
        }

    fun appendCatalogFiles(
        catalogFiles: List<CameraFile>,
        additionalFiles: List<CameraFile>,
    ): List<CameraFile> {
        if (additionalFiles.isEmpty()) return catalogFiles
        val existingHandles = catalogFiles.map { it.info.handle }.toSet()
        val newFiles = additionalFiles.filterNot { it.info.handle in existingHandles }
        if (newFiles.isEmpty()) return catalogFiles
        return catalogFiles + newFiles.map { it.copy(thumbnail = null) }
    }

    fun handlesNeedingMetadata(
        catalogFiles: List<CameraFile>,
        objectInfoByHandle: Map<Int, ObjectInfo>,
    ): List<Int> =
        catalogFiles
            .filter { file ->
                val resolved = objectInfoByHandle[file.info.handle]
                if (resolved == null) {
                    GalleryFastInitialLoadPolicy.needsFullObjectInfo(file)
                } else {
                    GalleryFastInitialLoadPolicy.needsFullObjectInfo(file.copy(info = resolved))
                }
            }
            .map { it.info.handle }

    private fun mergeResolvedMetadata(
        catalogFile: CameraFile,
        resolvedInfo: ObjectInfo,
    ): CameraFile =
        catalogFile.copy(
            info = resolvedInfo.copy(
                captureDate = resolvedCaptureDate(
                    catalogCaptureDate = catalogFile.info.captureDate,
                    resolvedCaptureDate = resolvedInfo.captureDate,
                ),
            ),
            thumbnail = catalogFile.thumbnail,
        )

    private fun resolvedCaptureDate(
        catalogCaptureDate: String,
        resolvedCaptureDate: String,
    ): String {
        val catalogDay = captureDayKey(catalogCaptureDate)
        val resolvedDay = captureDayKey(resolvedCaptureDate)
        return when {
            catalogDay == null -> resolvedCaptureDate
            resolvedDay == null -> catalogCaptureDate
            catalogDay == resolvedDay -> resolvedCaptureDate
            else -> catalogCaptureDate
        }
    }

    private fun captureDayKey(captureDate: String): String? {
        if (captureDate.length < 8) return null
        val day = captureDate.take(8)
        return runCatching {
            LocalDate.parse(day, DateTimeFormatter.BASIC_ISO_DATE)
            day
        }.getOrNull()
    }
}
