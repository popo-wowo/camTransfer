package com.camtransfer.service

object CameraPairingGuidance {
    const val CAMERA_MENU_PATH = "网络/USB设置 - 蓝牙/智能手机设置 - 配对注册"
    const val IDLE_HINT = "第一次使用先看连接教程；配对前请让相机进入配对注册，并清理手机里可能残留的旧蓝牙记录。"
    const val SCANNING_STATUS =
        "正在搜索相机\n" +
            "请确认：1. 相机停留在“配对注册 / PAIRING REGISTRATION”界面；" +
            "2. 如果以前配过这台相机，手机系统蓝牙里的旧蓝牙记录已经删除。"
    const val BLE_PAIRING_STATUS =
        "正在和相机建立蓝牙配对\n" +
            "如果手机弹出蓝牙配对请求，请点“配对/允许”。如果相机屏幕提示确认，也请按一下相机上的 OK/确定。"
    const val WAITING_CAMERA_CONFIRMATION_STATUS =
        "App 已把配对信息发给相机\n" +
            "请看相机屏幕：如果出现确认、OK 或配对完成提示，请在相机上按 OK/确定。看到相机显示配对成功后，再点下面按钮。"
}
