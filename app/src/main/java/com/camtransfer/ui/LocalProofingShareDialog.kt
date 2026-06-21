package com.camtransfer.ui

import android.graphics.Bitmap
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog

data class LocalProofingShareUiState(
    val url: String,
    val qrBitmap: Bitmap,
    val photoCount: Int,
)

@Composable
fun LocalProofingShareDialog(
    state: LocalProofingShareUiState,
    onDismiss: () -> Unit,
) {
    Dialog(onDismissRequest = onDismiss) {
        Surface(
            shape = RoundedCornerShape(8.dp),
            color = CamTransferColors.Card,
            border = BorderStroke(1.dp, CamTransferColors.Hairline),
            shadowElevation = 18.dp,
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(18.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    "现场分享",
                    color = CamTransferColors.Ink,
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Black,
                )
                Text(
                    "让另一台手机先连接同一个相机 Wi-Fi，再扫码查看 ${state.photoCount} 张照片。",
                    color = CamTransferColors.SecondaryInk,
                    style = MaterialTheme.typography.bodyMedium,
                    textAlign = TextAlign.Center,
                )
                Surface(
                    shape = RoundedCornerShape(6.dp),
                    color = CamTransferColors.WarmFill,
                    border = BorderStroke(1.dp, CamTransferColors.Hairline),
                ) {
                    Image(
                        bitmap = state.qrBitmap.asImageBitmap(),
                        contentDescription = "照片分享二维码",
                        modifier = Modifier
                            .size(250.dp)
                            .padding(10.dp),
                    )
                }
                Text(
                    state.url,
                    color = CamTransferColors.SecondaryInk,
                    style = MaterialTheme.typography.bodySmall,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(2.dp))
                Button(
                    onClick = onDismiss,
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = CamTransferColors.Ink,
                        contentColor = CamTransferColors.Card,
                    ),
                ) {
                    Text("停止分享")
                }
            }
        }
    }
}
