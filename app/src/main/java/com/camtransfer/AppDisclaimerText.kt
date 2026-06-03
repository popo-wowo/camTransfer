package com.camtransfer

data class AppDisclaimerSection(
    val title: String,
    val body: String,
    val highlights: List<String> = emptyList(),
)

object AppDisclaimerText {
    const val ACCEPTANCE_PREFS = "camtransfer.disclaimer"
    const val ACCEPTED_KEY = "accepted_v1"

    fun sections(trialDays: Long): List<AppDisclaimerSection> = listOf(
        AppDisclaimerSection(
            title = "内测有效期",
            body = "本 App 为内测版本，有效期为 $trialDays 天。到期后，部分或全部功能将无法继续使用，请联系开发者获取后续版本或授权方式。",
            highlights = listOf("$trialDays 天", "到期后"),
        ),
        AppDisclaimerSection(
            title = "隐私与联网",
            body = "本 App 不需要联网服务器，不会上传、收集、分析或出售用户的照片、视频、通讯录、位置、账号等个人信息。",
            highlights = listOf("不需要联网服务器", "不会上传、收集、分析或出售"),
        ),
        AppDisclaimerSection(
            title = "权限用途",
            body = "本 App 申请的蓝牙、Wi-Fi、相册/存储等权限，仅用于连接相机、读取相机文件列表、传输照片/视频并保存到用户手机本地。",
            highlights = listOf("仅用于连接相机", "保存到用户手机本地"),
        ),
        AppDisclaimerSection(
            title = "数据风险",
            body = "用户应自行备份重要照片和视频。因相机断开、传输中断、手机存储空间不足、系统权限限制、设备兼容性等原因导致的传输失败或文件异常，本 App 不承担数据丢失责任。",
            highlights = listOf("自行备份重要照片和视频", "不承担数据丢失责任"),
        ),
        AppDisclaimerSection(
            title = "合法使用",
            body = "本 App 仅供合法的个人照片/视频传输使用。用户应确保其传输、保存和使用的内容来源合法，并自行承担相应责任。",
            highlights = listOf("来源合法", "自行承担相应责任"),
        ),
        AppDisclaimerSection(
            title = "非官方声明",
            body = "本 App 由个人开发者独立开发，并非 FUJIFILM / 富士胶片官方应用，也未获得 FUJIFILM / 富士胶片官方授权、认证、赞助或背书。",
            highlights = listOf("个人开发者独立开发", "并非 FUJIFILM / 富士胶片官方应用", "未获得 FUJIFILM / 富士胶片官方授权"),
        ),
        AppDisclaimerSection(
            title = "品牌名称说明",
            body = "FUJIFILM、富士胶片及相关相机型号名称、商标、品牌标识均归其各自权利人所有。本 App 中提及相关品牌或型号，仅用于说明设备兼容性和功能用途，不代表与相关品牌存在任何官方合作或隶属关系。",
            highlights = listOf("归其各自权利人所有", "不代表与相关品牌存在任何官方合作"),
        ),
        AppDisclaimerSection(
            title = "设备兼容性",
            body = "用户在使用本 App 连接相机前，应自行确认相机设置、固件版本和数据安全风险。因第三方设备兼容性、相机固件变化、连接中断或用户操作导致的问题，由用户自行承担相应风险。",
            highlights = listOf("自行确认", "自行承担相应风险"),
        ),
        AppDisclaimerSection(
            title = "联系开发者",
            body = "如需联系开发者、反馈问题或获取后续版本，请通过 App 内显示的联系方式联系。",
            highlights = listOf("App 内显示的联系方式"),
        ),
    )

    fun fullText(trialDays: Long): String =
        sections(trialDays).joinToString(separator = "\n\n") { "${it.title}\n${it.body}" }
}
