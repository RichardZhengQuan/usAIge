import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans-SG"

    static let defaultsKey = "usageHUD.language"
    var id: Self { self }
    static var current: Self { Self(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system }

    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .english: Locale(identifier: Locale.autoupdatingCurrent.regionCode.map { "en_" + $0 } ?? "en")
        case .simplifiedChinese: Locale(identifier: "zh-Hans-SG")
        }
    }

    /// The distributable app puts its localizations beside the icon. SwiftPM's
    /// test host and command-line executable use the same resources in a bundle.
    static let resourceBundle: Bundle = {
        if Bundle.main.url(forResource: "zh-Hans-SG", withExtension: "lproj") != nil { return .main }
        return .module
    }()

    private static let chineseBundle = resourceBundle.url(forResource: "zh-Hans-SG", withExtension: "lproj")
        .flatMap(Bundle.init(url:))

    static func text(_ key: String, locale: Locale = current.locale) -> String {
        guard locale.languageCode == "zh",
              !locale.identifier.lowercased().contains("hant"),
              !["TW", "HK", "MO"].contains(locale.regionCode ?? "") else { return key }
        return chineseBundle?.localizedString(forKey: key, value: key, table: nil) ?? key
    }

    static func format(_ key: String, locale: Locale = current.locale, _ arguments: CVarArg...) -> String {
        String(format: text(key, locale: locale), locale: locale, arguments: arguments)
    }
}

struct AppLanguageEnvironment<Content: View>: View {
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system
    let content: Content
    var body: some View { content.environment(\.locale, language.locale) }
}

extension View {
    func appLanguageEnvironment() -> AppLanguageEnvironment<Self> { AppLanguageEnvironment(content: self) }
}

struct AppLanguagePicker: View {
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system
    @Environment(\.locale) private var locale
    var body: some View {
        HStack(spacing: 12) {
            Text("Language", bundle: AppLanguage.resourceBundle)
            Spacer(minLength: 4)
            Picker(selection: $language) {
                Text(verbatim: AppLanguage.text("System Default", locale: locale)).tag(AppLanguage.system)
                Text(verbatim: "English").tag(AppLanguage.english)
                Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
            } label: {
                Text("Language", bundle: AppLanguage.resourceBundle)
            }
            .labelsHidden()
            .pickerStyle(SegmentedPickerStyle())
            .fixedSize()
            .accessibilityIdentifier("settings.language")
        }
    }
}
