package com.camtransfer

import org.junit.Assert.assertTrue
import org.junit.Test

class AppDisclaimerTextTest {
    @Test
    fun disclaimerMentionsPrivacyTrialAndUnofficialBrandStatus() {
        val text = AppDisclaimerText.fullText(trialDays = 60)
        val sections = AppDisclaimerText.sections(trialDays = 60)

        assertTrue(text.contains("不需要联网服务器"))
        assertTrue(text.contains("不会上传、收集、分析或出售"))
        assertTrue(text.contains("60 天"))
        assertTrue(text.contains("并非 FUJIFILM / 富士胶片官方应用"))
        assertTrue(text.contains("未获得 FUJIFILM / 富士胶片官方授权"))
        assertTrue(sections.any { it.title == "隐私与联网" && it.highlights.contains("不需要联网服务器") })
        assertTrue(sections.any { it.title == "非官方声明" && it.highlights.contains("并非 FUJIFILM / 富士胶片官方应用") })
    }
}
