import Foundation

public struct LanguagePair: Hashable, Sendable {
    public let source: LangCode
    public let target: LangCode
}

public struct TransliterationResult: Sendable, Equatable {
    public let source: LangCode
    public let target: LangCode
    public let convertedText: String
}

public struct LanguageProfile: Sendable {
    public let code: LangCode
    public let label: String
    public let macosSourceIDs: [String]
    public let layoutChars: String
    public let charset: Set<Character>
    public let prefixScores: [String: Double]

    public init(
        code: LangCode,
        label: String,
        macosSourceIDs: [String],
        layoutChars: String,
        prefixScores: [String: Double] = [:]
    ) {
        self.code = code
        self.label = label
        self.macosSourceIDs = macosSourceIDs
        self.layoutChars = layoutChars
        self.charset = Set(layoutChars)
        self.prefixScores = prefixScores
    }
}

/// Провайдер частот слів (заміна бібліотеки `wordfreq`)
public protocol WordFrequencyProvider: Sendable {
    func topWords(for language: LangCode, limit: Int) -> [String]
    func zipfFrequency(of word: String, language: LangCode) -> Double
}

public final class PrefixLanguageDetector: Sendable {
    public static let enLayout =
        "`qwertyuiop[]asdfghjkl;'zxcvbnm,./\\" +
        "~QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?|"

    public static let ukLayout =
        "'йцукенгшщзхїфівапролджєячсмитьбю.ґ" +
        "ʼЙЦУКЕНГШЩЗХЇФІВАПРОЛДЖЄЯЧСМИТЬБЮ,Ґ"

    public static let vocabLimit = 50_000
    public static let sourceKeepThreshold = 4.2
    public static let targetMinThreshold = 3.8
    public static let minScoreDelta = 2.2

    public let minPrefixLength: Int
    private let frequencyProvider: any WordFrequencyProvider
    private let languageOrder: [LangCode]
    private let profiles: [LangCode: LanguageProfile]
    private let conversionMaps: [LanguagePair: [Character: Character]]

    public init(
        minPrefixLength: Int = 3,
        frequencyProvider: any WordFrequencyProvider
    ) {
        precondition(
            minPrefixLength > 0,
            "Мінімальна довжина префікса повинна бути більшою за 0"
        )
        precondition(
            Self.enLayout.count == Self.ukLayout.count,
            "Довжини рядків розкладок повинні збігатися"
        )

        self.minPrefixLength = minPrefixLength
        self.frequencyProvider = frequencyProvider

        let defaultConfigs: [(LangCode, String, [String], String)] = [
            (
                .en,
                "English",
                ["com.apple.keylayout.ABC", "com.apple.keylayout.US"],
                Self.enLayout
            ),
            (
                .uk,
                "Українська",
                ["com.apple.keylayout.Ukrainian-PC", "com.apple.keylayout.Ukrainian"],
                Self.ukLayout
            )
        ]

        var order: [LangCode] = []
        var builtProfiles: [LangCode: LanguageProfile] = [:]
        var builtMaps: [LanguagePair: [Character: Character]] = [:]

        for (code, label, sourceIDs, layout) in defaultConfigs {
            let profile = Self.buildProfile(
                code: code,
                label: label,
                macosSourceIDs: sourceIDs,
                layoutChars: layout,
                minPrefixLength: minPrefixLength,
                provider: frequencyProvider
            )
            order.append(code)
            builtProfiles[code] = profile

            for (otherCode, otherProfile) in builtProfiles where otherCode != code {
                builtMaps[LanguagePair(source: code, target: otherCode)] =
                    Self.makeTranslationMap(from: profile.layoutChars, to: otherProfile.layoutChars)
                builtMaps[LanguagePair(source: otherCode, target: code)] =
                    Self.makeTranslationMap(from: otherProfile.layoutChars, to: profile.layoutChars)
            }
        }

        self.languageOrder = order
        self.profiles = builtProfiles
        self.conversionMaps = builtMaps
    }

    private static func buildProfile(
        code: LangCode,
        label: String,
        macosSourceIDs: [String],
        layoutChars: String,
        minPrefixLength: Int,
        provider: any WordFrequencyProvider
    ) -> LanguageProfile {
        let words = provider.topWords(for: code, limit: vocabLimit)
        var prefixScores: [String: Double] = [:]
        prefixScores.reserveCapacity(words.count / 2)

        for word in words {
            let clean = word.lowercased()
            guard clean.count >= minPrefixLength else { continue }
            let prefix = String(clean.prefix(minPrefixLength))
            let score = provider.zipfFrequency(of: clean, language: code)
            if score > (prefixScores[prefix] ?? 0.0) {
                prefixScores[prefix] = score
            }
        }

        return LanguageProfile(
            code: code,
            label: label,
            macosSourceIDs: macosSourceIDs,
            layoutChars: layoutChars,
            prefixScores: prefixScores
        )
    }

    private static func makeTranslationMap(from source: String, to target: String) -> [Character: Character] {
        Dictionary(uniqueKeysWithValues: zip(source, target))
    }

    private func translate(_ text: String, using map: [Character: Character]) -> String {
        String(text.map { map[$0] ?? $0 })
    }

    public func detectSourceLanguage(in text: String) -> LangCode? {
        guard !text.isEmpty else { return nil }

        var counts: [LangCode: Int] = [:]

        for ch in text where !ch.isWhitespace {
            for code in languageOrder {
                if let profile = profiles[code], profile.charset.contains(ch) {
                    counts[code, default: 0] += 1
                }
            }
        }

        var bestCode: LangCode?
        var bestCount = 0

        for code in languageOrder {
            let count = counts[code] ?? 0
            if count > bestCount {
                bestCount = count
                bestCode = code
            }
        }

        return bestCode
    }

    public func forceTransliterate(
        _ text: String,
        preferredSource: LangCode? = nil
    ) -> TransliterationResult? {
        guard !text.isEmpty,
              let sourceLang = detectSourceLanguage(in: text) ?? preferredSource else {
            return nil
        }

        for targetLang in languageOrder where targetLang != sourceLang {
            let pair = LanguagePair(source: sourceLang, target: targetLang)
            if let transMap = conversionMaps[pair] {
                return TransliterationResult(
                    source: sourceLang,
                    target: targetLang,
                    convertedText: translate(text, using: transMap)
                )
            }
        }
        return nil
    }

    private func scoreToken(_ token: String, profile: LanguageProfile) -> Double {
        let lowered = token.lowercased()
        let prefix = String(lowered.prefix(minPrefixLength))
        let prefixScore = profile.prefixScores[prefix] ?? 0.0
        let fullScore = frequencyProvider.zipfFrequency(of: lowered, language: profile.code)
        return max(prefixScore, fullScore)
    }

    public func evaluateSwitch(for token: String) -> TransliterationResult? {
        guard token.count >= minPrefixLength,
              let sourceLang = detectSourceLanguage(in: token),
              let sourceProfile = profiles[sourceLang] else {
            return nil
        }

        let sourceScore = scoreToken(token, profile: sourceProfile)
        if sourceScore >= Self.sourceKeepThreshold {
            return nil
        }

        var bestTarget: LangCode?
        var bestConverted = ""
        var bestScore = 0.0

        for targetLang in languageOrder where targetLang != sourceLang {
            guard let targetProfile = profiles[targetLang] else { continue }
            let pair = LanguagePair(source: sourceLang, target: targetLang)
            guard let transMap = conversionMaps[pair] else { continue }

            let convertedToken = translate(token, using: transMap)
            let targetScore = scoreToken(convertedToken, profile: targetProfile)

            if targetScore > bestScore {
                bestScore = targetScore
                bestTarget = targetLang
                bestConverted = convertedToken
            }
        }

        guard let target = bestTarget,
              bestScore >= Self.targetMinThreshold,
              (bestScore - sourceScore) >= Self.minScoreDelta else {
            return nil
        }

        return TransliterationResult(
            source: sourceLang,
            target: target,
            convertedText: bestConverted
        )
    }
}
