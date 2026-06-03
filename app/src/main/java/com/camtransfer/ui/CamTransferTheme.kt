package com.camtransfer.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

object CamTransferColors {
    val Background = Color(0xFFF8F7F4)
    val Card = Color.White
    val Ink = Color(0xFF171717)
    val SecondaryInk = Color(0xFF6E6B63)
    val Hairline = Color(0x1A171717)
    val Accent = Color(0xFF9E8257)
    val WarmFill = Color(0xFFFFFDF9)
    val MutedFill = Color(0xB8FFFFFF)
}

private val CamTransferLightScheme = lightColorScheme(
    primary = CamTransferColors.Ink,
    onPrimary = CamTransferColors.Card,
    secondary = CamTransferColors.Accent,
    onSecondary = CamTransferColors.Card,
    background = CamTransferColors.Background,
    onBackground = CamTransferColors.Ink,
    surface = CamTransferColors.Background,
    onSurface = CamTransferColors.Ink,
    surfaceVariant = Color(0xFFEDEBE5),
    onSurfaceVariant = CamTransferColors.SecondaryInk,
    outline = CamTransferColors.Hairline,
)

@Composable
fun CamTransferTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = CamTransferLightScheme,
        content = content,
    )
}
