package com.camtransfer.localproofing

import com.camtransfer.model.CameraFile
import java.net.URLDecoder
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import kotlin.math.roundToInt

data class LocalProofingPhoto(
    val id: String,
    val filename: String,
    val detail: String,
    val formatLabel: String,
    val hasPreview: Boolean,
)

object LocalProofingPhotoMapper {
    fun photo(file: CameraFile): LocalProofingPhoto {
        val info = file.info
        return LocalProofingPhoto(
            id = info.handle.toString(),
            filename = info.filename,
            detail = "${info.formatLabel} · ${formatBytes(info.compressedSize)}",
            formatLabel = info.formatLabel,
            hasPreview = file.thumbnail != null,
        )
    }

    private fun formatBytes(bytes: Int): String {
        if (bytes <= 0) return "未知大小"
        val mb = bytes / (1024.0 * 1024.0)
        if (mb >= 1.0) return "${(mb * 10).roundToInt() / 10.0} MB"
        val kb = bytes / 1024.0
        return "${kb.roundToInt()} KB"
    }
}

data class LocalProofingNetworkInterface(
    val name: String,
    val address: String,
)

object LocalProofingNetworkPolicy {
    private val preferredWifiInterfaceNames = listOf("wlan0", "en0", "ap0", "bridge100")

    fun preferredAddress(interfaces: List<LocalProofingNetworkInterface>): LocalProofingNetworkInterface? {
        val privateInterfaces = interfaces.filter {
            it.name != "lo" && isPrivateIPv4Address(it.address)
        }
        preferredWifiInterfaceNames.forEach { preferredName ->
            privateInterfaces.firstOrNull { it.name == preferredName }?.let { return it }
        }
        return privateInterfaces.firstOrNull { !it.name.startsWith("rmnet") }
    }

    fun shareUrl(address: String, port: Int, token: String): String =
        "http://$address:$port/s/$token"

    private fun isPrivateIPv4Address(address: String): Boolean {
        val parts = address.split(".").mapNotNull { it.toIntOrNull() }
        if (parts.size != 4) return false
        return when {
            parts[0] == 10 -> true
            parts[0] == 192 && parts[1] == 168 -> true
            parts[0] == 172 && parts[1] in 16..31 -> true
            else -> false
        }
    }
}

data class LocalProofingHttpRequest(
    val method: String,
    val path: String,
    val body: ByteArray = ByteArray(0),
)

data class LocalProofingHttpResponse(
    val statusCode: Int,
    val contentType: String,
    val body: ByteArray,
) {
    val wireBytes: ByteArray
        get() {
            val head = buildString {
                append("HTTP/1.1 ")
                append(statusCode)
                append(' ')
                append(reasonPhrase)
                append("\r\nContent-Type: ")
                append(contentType)
                append("\r\nContent-Length: ")
                append(body.size)
                append("\r\nCache-Control: no-store")
                append("\r\nConnection: close")
                append("\r\nAccess-Control-Allow-Origin: *")
                append("\r\n\r\n")
            }.toByteArray(StandardCharsets.UTF_8)
            return head + body
        }

    private val reasonPhrase: String
        get() = when (statusCode) {
            200 -> "OK"
            400 -> "Bad Request"
            404 -> "Not Found"
            else -> "OK"
        }

    companion object {
        fun ok(contentType: String, body: ByteArray) =
            LocalProofingHttpResponse(200, contentType, body)

        fun badRequest() =
            LocalProofingHttpResponse(400, "application/json", """{"error":"bad_request"}""".toByteArray())

        fun notFound() =
            LocalProofingHttpResponse(404, "application/json", """{"error":"not_found"}""".toByteArray())
    }
}

class LocalProofingRequestRouter(
    private val sessionToken: String,
    private val photosProvider: () -> List<LocalProofingPhoto>,
    private val previewProvider: (String) -> ByteArray?,
    private val logger: (String) -> Unit = {},
) {
    fun responseFor(request: LocalProofingHttpRequest): LocalProofingHttpResponse {
        val method = request.method.uppercase()
        val path = request.path.substringBefore("?")
        val response = when {
            method == "GET" && path == "/s/$sessionToken" -> {
                logger("route page status=200 path=$path")
                LocalProofingHttpResponse.ok("text/html; charset=utf-8", galleryHtml().toByteArray())
            }

            method == "GET" && path == "/health" -> {
                logger("route health status=200")
                LocalProofingHttpResponse.ok("application/json", """{"ok":true}""".toByteArray())
            }

            method == "GET" && path == "/api/photos" -> {
                val photos = photosProvider()
                logger("route photos status=200 count=${photos.size} previews=${photos.count { it.hasPreview }}")
                LocalProofingHttpResponse.ok("application/json", photosJson(photos).toByteArray())
            }

            method == "GET" && path.startsWith("/preview/") && path.endsWith(".jpg") -> {
                val encodedId = path.removePrefix("/preview/").removeSuffix(".jpg")
                val id = URLDecoder.decode(encodedId, StandardCharsets.UTF_8.name())
                previewProvider(id)?.let { data ->
                    logger("route preview status=200 id=$id bytes=${data.size}")
                    LocalProofingHttpResponse.ok("image/jpeg", data)
                } ?: run {
                    logger("route preview status=404 id=$id")
                    LocalProofingHttpResponse.notFound()
                }
            }

            else -> {
                logger("route notFound status=404 method=$method path=$path")
                LocalProofingHttpResponse.notFound()
            }
        }
        return response
    }

    private fun photosJson(sourcePhotos: List<LocalProofingPhoto>): String {
        val photos = sourcePhotos.joinToString(separator = ",") { photo ->
            val previewUrl = if (photo.hasPreview) {
                "\"/preview/${encodePath(photo.id)}.jpg\""
            } else {
                "null"
            }
            buildString {
                append('{')
                append("\"id\":\"").append(jsonEscape(photo.id)).append("\",")
                append("\"filename\":\"").append(jsonEscape(photo.filename)).append("\",")
                append("\"detail\":\"").append(jsonEscape(photo.detail)).append("\",")
                append("\"formatLabel\":\"").append(jsonEscape(photo.formatLabel)).append("\",")
                append("\"previewURL\":").append(previewUrl)
                append('}')
            }
        }
        return """{"photos":[$photos]}"""
    }

    private fun galleryHtml(): String =
        """
        <!doctype html>
        <html lang="zh-Hans">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <title>现场选片</title>
          <style>
            :root { color-scheme: light; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #f5f2ec; color: #171511; }
            body { margin: 0; padding: 18px; }
            header { position: sticky; top: 0; z-index: 2; margin: -18px -18px 14px; padding: 14px 18px 12px; background: rgba(245,242,236,.94); backdrop-filter: blur(14px); border-bottom: 1px solid rgba(23,21,17,.08); }
            h1 { margin: 0; font-size: 20px; line-height: 1.2; }
            .meta { margin-top: 4px; font-size: 13px; color: #6f675d; }
            .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(122px, 1fr)); gap: 10px; }
            .photo { text-align: left; background: #fffaf2; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 8px rgba(23,21,17,.09); }
            .thumb { aspect-ratio: 1; background: #ded8ce; display: grid; place-items: center; color: #80776b; font-size: 13px; }
            .thumb img { width: 100%; height: 100%; object-fit: cover; display: block; }
            .caption { padding: 8px; min-height: 44px; }
            .name { font-size: 12px; font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
            .detail { margin-top: 2px; font-size: 11px; color: #7a7167; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
            .viewer { position: fixed; inset: 0; z-index: 9; display: none; background: rgba(14,13,11,.94); color: #fffaf2; }
            .viewer.open { display: grid; grid-template-rows: auto 1fr auto; }
            .viewerTop { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: calc(12px + env(safe-area-inset-top)) 14px 10px; }
            .viewerTitle { min-width: 0; font-size: 14px; font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
            .viewerClose { border: 0; border-radius: 18px; padding: 8px 12px; background: rgba(255,250,242,.14); color: #fffaf2; font-weight: 700; }
            .viewerStage { min-height: 0; display: grid; place-items: center; overflow: hidden; }
            .viewerStage img { max-width: 100%; max-height: 100%; object-fit: contain; }
            .viewerFooter { padding: 10px 14px calc(14px + env(safe-area-inset-bottom)); font-size: 13px; color: rgba(255,250,242,.78); }
            .fallback { margin-top: 16px; padding: 14px; border-radius: 8px; background: #fffaf2; color: #6f675d; font-size: 13px; line-height: 1.5; }
            .retry { margin-top: 10px; border: 0; border-radius: 18px; padding: 9px 14px; background: #171511; color: #fffaf2; font-weight: 700; }
          </style>
        </head>
        <body>
          <header>
            <h1>现场选片</h1>
            <div class="meta" id="status">正在载入照片</div>
          </header>
          <noscript><div class="fallback">浏览器关闭了 JavaScript，无法载入照片列表。请换系统浏览器扫码。</div></noscript>
          <main class="grid" id="grid"></main>
          <div class="fallback" id="fallback">如果页面一直停在这里，请确认两台手机都连接同一个相机 Wi-Fi，然后点刷新。</div>
          <section class="viewer" id="viewer" aria-hidden="true">
            <div class="viewerTop"><div class="viewerTitle" id="viewerTitle"></div><button class="viewerClose" type="button" onclick="closeViewer()">关闭</button></div>
            <div class="viewerStage" onclick="closeViewer()"><img id="viewerImage" alt=""></div>
            <div class="viewerFooter" id="viewerDetail"></div>
          </section>
          <script>
            const grid = document.getElementById('grid');
            const status = document.getElementById('status');
            const viewer = document.getElementById('viewer');
            const viewerImage = document.getElementById('viewerImage');
            const viewerTitle = document.getElementById('viewerTitle');
            const viewerDetail = document.getElementById('viewerDetail');
            const fallback = document.getElementById('fallback');
            async function loadPhotos() {
              const response = await fetch('/api/photos', { cache: 'no-store' });
              if (!response.ok) throw new Error('photos api ' + response.status);
              const payload = await response.json();
              const photos = payload.photos || [];
              status.textContent = photos.length + ' 张照片';
              grid.innerHTML = '';
              fallback.style.display = photos.length ? 'none' : 'block';
              fallback.textContent = photos.length ? '' : '当前没有可显示的照片缩略图。请先在摄影师手机上等待相机照片加载完成。';
              for (const photo of photos) {
                const card = document.createElement('article');
                card.className = 'photo';
                const image = photo.previewURL ? '<img src="' + photo.previewURL + '" alt="">' : '<span>' + (photo.formatLabel || 'PHOTO') + '</span>';
                card.innerHTML = '<button class="thumb" type="button">' + image + '</button><div class="caption"><div class="name"></div><div class="detail"></div></div>';
                card.querySelector('.thumb').onclick = () => openViewer(photo);
                card.querySelector('.name').textContent = photo.filename;
                card.querySelector('.detail').textContent = photo.detail || photo.formatLabel || '';
                grid.appendChild(card);
              }
            }
            function openViewer(photo) {
              if (!photo.previewURL) return;
              viewerImage.src = photo.previewURL;
              viewerTitle.textContent = photo.filename;
              viewerDetail.textContent = photo.detail || photo.formatLabel || '';
              viewer.classList.add('open');
              viewer.setAttribute('aria-hidden', 'false');
            }
            function closeViewer() {
              viewer.classList.remove('open');
              viewer.setAttribute('aria-hidden', 'true');
              viewerImage.removeAttribute('src');
            }
            loadPhotos().catch((error) => {
              status.textContent = '无法载入照片';
              fallback.style.display = 'block';
              fallback.innerHTML = '浏览器已打开分享页，但照片列表请求失败：' + error.message + '<br><button class="retry" type="button" onclick="loadPhotos()">刷新</button>';
            });
            setInterval(() => loadPhotos().catch(() => {}), 4000);
          </script>
        </body>
        </html>
        """.trimIndent()

    private fun jsonEscape(value: String): String =
        value.flatMap { char ->
            when (char) {
                '\\' -> "\\\\".toList()
                '"' -> "\\\"".toList()
                '\n' -> "\\n".toList()
                '\r' -> "\\r".toList()
                '\t' -> "\\t".toList()
                else -> listOf(char)
            }
        }.joinToString("")

    private fun encodePath(value: String): String =
        URLEncoder.encode(value, StandardCharsets.UTF_8.name()).replace("+", "%20")
}

object LocalProofingSessionToken {
    private const val ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

    fun make(length: Int = 6): String =
        (0 until length).map { ALPHABET.random() }.joinToString("")
}
