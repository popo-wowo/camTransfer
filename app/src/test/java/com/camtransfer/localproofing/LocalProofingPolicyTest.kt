package com.camtransfer.localproofing

import com.camtransfer.model.CameraFile
import com.camtransfer.model.ObjectInfo
import com.camtransfer.protocol.PtpObjectFormat
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalProofingPolicyTest {
    @Test
    fun preferredAddressUsesPrivateWifiInterface() {
        val selected = LocalProofingNetworkPolicy.preferredAddress(
            listOf(
                LocalProofingNetworkInterface("rmnet_data0", "10.20.30.40"),
                LocalProofingNetworkInterface("wlan0", "192.168.0.138"),
                LocalProofingNetworkInterface("lo", "127.0.0.1"),
            )
        )

        assertEquals(LocalProofingNetworkInterface("wlan0", "192.168.0.138"), selected)
    }

    @Test
    fun shareUrlPointsAtSessionPathOnAdvertisedPhoneAddress() {
        val url = LocalProofingNetworkPolicy.shareUrl(
            address = "192.168.0.138",
            port = 8080,
            token = "ABCD23",
        )

        assertEquals("http://192.168.0.138:8080/s/ABCD23", url)
    }

    @Test
    fun photoMapperUsesGalleryMetadataAndOnlyMarksExistingPreviews() {
        val photo = LocalProofingPhotoMapper.photo(
            file(
                handle = 10,
                filename = "DSCF0010.JPG",
                size = 3_456_789,
                thumbnail = byteArrayOf(1, 2, 3),
            )
        )

        assertEquals("10", photo.id)
        assertEquals("DSCF0010.JPG", photo.filename)
        assertEquals("JPG", photo.formatLabel)
        assertEquals("JPG · 3.3 MB", photo.detail)
        assertTrue(photo.hasPreview)
    }

    @Test
    fun routerServesTokenPagePhotosJsonAndPreviewBytes() {
        val preview = byteArrayOf(0x01, 0x02, 0x03)
        val events = mutableListOf<String>()
        val router = LocalProofingRequestRouter(
            sessionToken = "ABCD23",
            photosProvider = {
                listOf(
                    LocalProofingPhotoMapper.photo(
                        file(
                            handle = 10,
                            filename = "DSCF0010.JPG",
                            size = 3_456_789,
                            thumbnail = preview,
                        )
                    )
                )
            },
            previewProvider = { id -> if (id == "10") preview else null },
            logger = events::add,
        )

        val page = router.responseFor(LocalProofingHttpRequest("GET", "/s/ABCD23"))
        assertEquals(200, page.statusCode)
        assertTrue(page.bodyText().contains("现场选片"))
        assertTrue(page.bodyText().contains("/api/photos"))
        assertTrue(page.bodyText().contains("如果页面一直停在这里"))

        val wrongToken = router.responseFor(LocalProofingHttpRequest("GET", "/s/WRONG"))
        assertEquals(404, wrongToken.statusCode)

        val photos = router.responseFor(LocalProofingHttpRequest("GET", "/api/photos"))
        assertEquals(200, photos.statusCode)
        assertTrue(photos.bodyText().contains("DSCF0010.JPG"))
        assertTrue(photos.bodyText().contains("/preview/10.jpg"))
        assertFalse(photos.bodyText().contains("thumbnail"))

        val previewResponse = router.responseFor(LocalProofingHttpRequest("GET", "/preview/10.jpg"))
        assertEquals(200, previewResponse.statusCode)
        assertEquals("image/jpeg", previewResponse.contentType)
        assertArrayEquals(preview, previewResponse.body)

        assertTrue(events.any { it.contains("route page status=200") })
        assertTrue(events.any { it.contains("route photos status=200 count=1") })
        assertTrue(events.any { it.contains("route preview status=200 id=10 bytes=3") })
    }

    private fun LocalProofingHttpResponse.bodyText(): String = body.toString(Charsets.UTF_8)

    private fun file(
        handle: Int,
        filename: String,
        size: Int,
        thumbnail: ByteArray?,
    ): CameraFile =
        CameraFile(
            ObjectInfo(
                handle = handle,
                storageId = 1,
                format = PtpObjectFormat.JPEG,
                compressedSize = size,
                thumbFormat = PtpObjectFormat.JPEG,
                thumbCompressedSize = 128,
                thumbPixWidth = 160,
                thumbPixHeight = 120,
                imagePixWidth = 4000,
                imagePixHeight = 3000,
                parentObject = 0,
                filename = filename,
                captureDate = "20260620T120000",
            ),
            thumbnail = thumbnail,
        )
}
