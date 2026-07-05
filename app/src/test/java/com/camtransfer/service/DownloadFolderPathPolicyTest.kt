package com.camtransfer.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DownloadFolderPathPolicyTest {
    @Test
    fun relativePathUsesConfiguredRootCameraAndDate() {
        val settings = DownloadFolderSettings(
            rootFolderName = "My Imports",
            includeCameraName = true,
            includeDateFolder = true,
        )

        assertEquals(
            "Pictures/My Imports/X-T5-Pro/2026-06-27",
            DownloadFolderPathPolicy.relativePath(
                mediaRootDirectory = "Pictures",
                settings = settings,
                cameraDisplayName = " X-T5/Pro ",
                captureDate = "20260627T101530",
            ),
        )
    }

    @Test
    fun relativePathFallsBackToDefaultRootAndSkipsUnavailableSegments() {
        val settings = DownloadFolderSettings(
            rootFolderName = "   ",
            includeCameraName = true,
            includeDateFolder = true,
        )

        assertEquals(
            "Movies/CamTransfer",
            DownloadFolderPathPolicy.relativePath(
                mediaRootDirectory = "Movies",
                settings = settings,
                cameraDisplayName = " / : * ? ",
                captureDate = "bad-date",
            ),
        )
    }

    @Test
    fun cameraAndFolderSanitizationRemovesPathBreakingCharacters() {
        assertEquals("Travel Imports", DownloadFolderPathPolicy.normalizedRootFolderName(" Travel Imports "))
        assertEquals("X-T5-Pro", DownloadFolderPathPolicy.sanitizedFolderSegment("X:T5/Pro"))
        assertNull(DownloadFolderPathPolicy.sanitizedFolderSegment(" / : * ? "))
    }

    @Test
    fun customFolderModeUsesChosenFolderAndDisablesRuleFolders() {
        val settings = DownloadFolderSettings(
            saveMode = DownloadFolderSaveMode.CUSTOM_TREE,
            rootFolderName = "Ignored",
            includeCameraName = true,
            includeDateFolder = true,
            customTreeUri = "content://tree/primary%3APictures%2FCameraDrops",
            customTreeLabel = "CameraDrops",
        )

        assertTrue(DownloadFolderPathPolicy.usesCustomTree(settings))
        assertEquals("CameraDrops", DownloadFolderPathPolicy.customFolderSummary(settings))
        assertFalse(DownloadFolderPathPolicy.shouldShowRuleOptions(settings))
    }
}
