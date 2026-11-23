import Foundation
import Testing
@testable import UsageHUD

@Suite struct AppLanguageTests {
    @Test func bothSupportedLanguagesLoadFromThePackagedCatalog() throws {
        let chinese = AppLanguage.simplifiedChinese.locale
        #expect(chinese.regionCode == "SG")
        #expect(chinese.languageCode == "zh")
        #expect(AppLanguage(rawValue: AppLanguage.simplifiedChinese.rawValue) == .simplifiedChinese)
        #expect(AppLanguage.resourceBundle.url(forResource: "zh-Hans-SG", withExtension: "lproj") != nil)
        for (english, translated) in [("Settings", "设置"), ("Show Floating Panel", "显示浮动面板"),
                                      ("Device docks", "设备组合"), ("Memory", "内存"), ("CPU usage", "CPU 使用率")] {
            #expect(AppLanguage.text(english, locale: chinese) == translated)
            #expect(AppLanguage.text(english, locale: AppLanguage.english.locale) == english)
        }
        #expect(AppLanguage.text("My repository", locale: chinese) == "My repository")
        #expect(AppLanguage.format("%@ resets %@", locale: chinese, "5H", "23:39") == "5H 重置时间：23:39")
        #expect(AppLanguage.format("%ld logical cores", locale: chinese, 12) == "12 个逻辑核心")
    }

    @Test func resetDatesUseSingaporeChineseWordingAndTheActualTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ResetMomentText.moment(now.addingTimeInterval(600), now: now,
                                     locale: AppLanguage.simplifiedChinese.locale) == "10 分钟后")
        #expect(ResetMomentText.sentence(nil, now: now, locale: AppLanguage.simplifiedChinese.locale) == "暂无重置时间")
    }
}
