import Foundation
import Observation

public enum LangCode: String, CaseIterable, Codable, Hashable, Sendable {
    case en
    case uk

    public static func detectSystemLanguage() -> LangCode {
        guard let primary = Locale.preferredLanguages.first?.lowercased(),
              primary.hasPrefix("uk") else {
            return .en
        }
        return .uk
    }
}

public enum HotkeyPreset: String, CaseIterable, Codable, Hashable, Sendable {
    case doubleShift = "double_shift"
    case doubleAlt = "double_alt"
    case doubleCtrl = "double_ctrl"
    case doubleCmd = "double_cmd"
    case keyF12 = "f12"
    case keyF6 = "f6"
    case keyCapsLock = "caps_lock"
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var uiLanguage: LangCode
    public var hotkeyPreset: HotkeyPreset
    public var autoSwitchEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case uiLanguage = "ui_language"
        case hotkeyPreset = "hotkey_preset"
        case autoSwitchEnabled = "auto_switch_enabled"
    }

    public init(
        uiLanguage: LangCode = .detectSystemLanguage(),
        hotkeyPreset: HotkeyPreset = .doubleShift,
        autoSwitchEnabled: Bool = true
    ) {
        self.uiLanguage = uiLanguage
        self.hotkeyPreset = hotkeyPreset
        self.autoSwitchEnabled = autoSwitchEnabled
    }

    // Стійке декодування: якщо якесь поле в JSON бите або відсутнє, беремо дефолтне
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.uiLanguage = (try? container.decode(LangCode.self, forKey: .uiLanguage))
            ?? .detectSystemLanguage()
        self.hotkeyPreset = (try? container.decode(HotkeyPreset.self, forKey: .hotkeyPreset))
            ?? .doubleShift
        self.autoSwitchEnabled = (try? container.decode(Bool.self, forKey: .autoSwitchEnabled))
            ?? true
    }

    public static var appSupportDirectoryURL: URL {
        let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Pablo Switcher"
        return URL.applicationSupportDirectory
            .appendingPathComponent(appName, isDirectory: true)
    }

    public static var defaultConfigURL: URL {
        appSupportDirectoryURL.appendingPathComponent("config.json")
    }

    public static var customVocabURL: URL {
        appSupportDirectoryURL.appendingPathComponent("custom_vocab.json")
    }

    public static func load(from url: URL = defaultConfigURL) -> AppSettings {
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else {
            let defaults = AppSettings()
            defaults.save(to: url)
            return defaults
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            AppLogger.shared.error(.settings, "Помилка читання config.json, використано стандартні налаштування: \(error.localizedDescription)")
            return AppSettings()
        }
    }

    public func save(to url: URL = defaultConfigURL) {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLogger.shared.error(.settings, "Помилка збереження config.json: \(error.localizedDescription)")
        }
    }
}

@MainActor
@Observable
public final class XMLI18nManager {
    private static let placeholderRegex = /\{([a-zA-Z0-9_]+)\}/

    private var translations: [LangCode: [String: String]] = [:]
    public var language: LangCode = .en

    public init(bundle: Bundle = .main, subdirectory: String? = "locales") {
        loadXMLFiles(from: bundle, subdirectory: subdirectory)
    }

    private func loadXMLFiles(from bundle: Bundle, subdirectory: String?) {
        for lang in LangCode.allCases {
            let url = bundle.url(forResource: lang.rawValue, withExtension: "xml", subdirectory: subdirectory)
                ?? bundle.url(forResource: lang.rawValue, withExtension: "xml")

            if let url {
                translations[lang] = Self.parseXMLFile(at: url, lang: lang)
            } else {
                AppLogger.shared.warning(.app, "Файл локалізації \(lang.rawValue).xml не знайдено у бандлі")
                translations[lang] = [:]
            }
        }
    }

    private static func parseXMLFile(at url: URL, lang: LangCode) -> [String: String] {
        guard let data = try? Data(contentsOf: url) else {
            AppLogger.shared.error(.app, "Не вдалося прочитати дані з \(lang.rawValue).xml")
            return [:]
        }

        let delegate = StringsXMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate

        guard parser.parse() else {
            let parseErr = parser.parserError?.localizedDescription ?? "невідома синтаксична помилка"
            AppLogger.shared.error(.app, "Помилка парсингу \(lang.rawValue).xml (рядок \(parser.lineNumber)): \(parseErr)")
            return [:]
        }

        return delegate.strings
    }

    public func t(_ key: String, args: [String: any CustomStringConvertible] = [:]) -> String {
        let langTable = translations[language] ?? [:]
        let fallbackTable = translations[.en] ?? [:]
        let template = langTable[key] ?? fallbackTable[key] ?? key

        guard !args.isEmpty else { return template }

        // Однопрохідна заміна захищає від повторної підстановки, якщо значення аргументу містить `{...}`
        return template.replacing(Self.placeholderRegex) { match in
            let argName = String(match.output.1)
            if let value = args[argName] {
                return "\(value)"
            }
            return String(match.output.0)
        }
    }

    public func hotkeyLabel(for preset: HotkeyPreset) -> String {
        t("hotkey_\(preset.rawValue)")
    }
}

private final class StringsXMLParserDelegate: NSObject, XMLParserDelegate {
    var strings: [String: String] = [:]
    private var currentKey: String?
    private var currentValue: String = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "string", let key = attributeDict["key"] {
            currentKey = key
            currentValue = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentKey != nil {
            currentValue += string
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if currentKey != nil, let text = String(data: CDATABlock, encoding: .utf8) {
            currentValue += text
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "string", let key = currentKey {
            strings[key] = currentValue.replacingOccurrences(of: "\\n", with: "\n")
            currentKey = nil
            currentValue = ""
        }
    }
}
