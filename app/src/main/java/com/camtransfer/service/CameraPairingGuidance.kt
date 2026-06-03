package com.camtransfer.service

object CameraPairingGuidance {
    const val CAMERA_MENU_PATH = "网络/USB设置 - 蓝牙/智能手机设置 - 配对注册"
    const val IDLE_HINT = "第一次使用请先查看连接教程，再点击连接相机。"
    const val SCANNING_STATUS =
        "正在搜索相机...\n请确认相机停留在“配对注册 / PAIRING REGISTRATION”界面。"
    const val BLE_PAIRING_STATUS =
        "正在蓝牙配对...\n如果手机弹出蓝牙配对请求，请点配对/允许；同时按相机屏幕提示确认。"
    const val WAITING_CAMERA_CONFIRMATION_STATUS =
        "看到相机显示配对成功后，再点确认。"
}
