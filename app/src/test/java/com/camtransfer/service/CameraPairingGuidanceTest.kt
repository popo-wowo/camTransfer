package com.camtransfer.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraPairingGuidanceTest {
    @Test
    fun cameraMenuPathNamesPairingRegistration() {
        assertEquals(
            "网络/USB设置 - 蓝牙/智能手机设置 - 配对注册",
            CameraPairingGuidance.CAMERA_MENU_PATH,
        )
    }

    @Test
    fun scanningStatusRemindsUserToStayOnPairingScreen() {
        assertTrue(CameraPairingGuidance.SCANNING_STATUS.contains("配对注册"))
        assertTrue(CameraPairingGuidance.SCANNING_STATUS.contains("PAIRING REGISTRATION"))
        assertTrue(CameraPairingGuidance.SCANNING_STATUS.contains("旧蓝牙"))
        assertTrue(CameraPairingGuidance.SCANNING_STATUS.contains("删除"))
    }

    @Test
    fun waitingConfirmationStatusTellsUserWhenToTapConfirm() {
        assertTrue(CameraPairingGuidance.WAITING_CAMERA_CONFIRMATION_STATUS.contains("相机显示配对成功"))
        assertTrue(CameraPairingGuidance.WAITING_CAMERA_CONFIRMATION_STATUS.contains("OK"))
        assertTrue(CameraPairingGuidance.WAITING_CAMERA_CONFIRMATION_STATUS.contains("确认"))
    }
}
