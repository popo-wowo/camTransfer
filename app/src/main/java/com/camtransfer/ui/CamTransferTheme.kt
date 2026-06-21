package com.camtransfer.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

object CamTransferColors {
    val Background = Color(0xFFF1EEE7)
    val Card = Color(0xFFFFFDF8)
    val Ink = Color(0xFF151515)
    val SecondaryInk = Color(0xFF706A60)
    val Hairline = Color(0x1A151515)
    val Accent = Color(0xFF9F7A45)
    val AccentSoft = Color(0xFFEFE2CA)
    val Blue = Color(0xFF2D6FBA)
    val BlueSoft = Color(0xFFE6F0FB)
    val Red = Color(0xFFB84632)
    val RedSoft = Color(0xFFF7E4DF)
    val WarmFill = Color(0xFFFFFDF8)
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
