//
//  BundledWordFrequencyProvider.swift
//  Pablo Switcher
//
//  Created by Serhii Meleshchuk on 23.11.2026.
//

import Foundation

nonisolated public final class BundledWordFrequencyProvider: WordFrequencyProvider, Sendable {
    /// Стандартний високий бал Zipf для слів із користувацького словника
    public static let defaultCustomZipfScore: Double = 6.5

    private struct LanguageDictionary: Decodable {
        let top: [String]
        let scores: [String: Double]

        private enum CodingKeys: String, CodingKey {
            case top
            case scores
        }

        init(top: [String], scores: [String: Double]) {
            self.top = top
            self.scores = scores
        }

        init(from decoder: Decoder) throws {
            // Варіант 1: структура {"top": [...], "scores": {...}}
            if let container = try? decoder.container(keyedBy: CodingKeys.self),
               let scores = try? container.decode([String: Double].self, forKey: .scores) {
                self.scores = scores
                if let top = try? container.decode([String].self, forKey: .top) {
                    self.top = top
                } else {
                    self.top = Self.sortByScore(scores)
                }
                return
            }

            // Варіант 2: плоский словник {"слово": частота}
            let singleContainer = try decoder.singleValueContainer()
            let flatScores = try singleContainer.decode([String: Double].self)
            self.scores = flatScores
            self.top = Self.sortByScore(flatScores)
        }

        private static func sortByScore(_ scores: [String: Double]) -> [String] {
            scores.sorted {
                if $0.value != $1.value {
                    return $0.value > $1.value
                }
                return $0.key < $1.key
            }.map(\.key)
        }
    }

    /// Підтримує як масив слів ["word1", "word2"], так і словник {"word1": 6.5}
    private enum CustomLanguageEntry: Decodable {
        case wordList([String])
        case scoreMap([String: Double])

        var isEmpty: Bool {
            switch self {
            case .wordList(let list): return list.isEmpty
            case .scoreMap(let map): return map.isEmpty
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let list = try? container.decode([String].self) {
                self = .wordList(list)
            } else if let map = try? container.decode([String: Double].self) {
                self = .scoreMap(map)
            } else {
                throw DecodingError.typeMismatch(
                    CustomLanguageEntry.self,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Очікувався масив рядків або словник [слово: частота]"
                    )
                )
            }
        }
    }

    private let dictionaries: [LangCode: LanguageDictionary]

    public init(
        bundle: Bundle = .main,
        subdirectory: String? = "resources",
        customVocabURL: URL = AppSettings.customVocabURL
    ) {
        var baseDictionaries = Self.loadBaseDictionaries(bundle: bundle, subdirectory: subdirectory)
        let customEntries = Self.loadOrCreateCustomVocab(at: customVocabURL)

        // Об'єднуємо базовий бінарний словник із користувацьким
        for lang in LangCode.allCases {
            let base = baseDictionaries[lang] ?? LanguageDictionary(top: [], scores: [:])
            guard let custom = customEntries[lang], !custom.isEmpty else {
                baseDictionaries[lang] = base
                continue
            }

            var mergedScores = base.scores
            var customWordsOrdered: [String] = []
            var customSet: Set<String> = []

            switch custom {
            case .wordList(let words):
                for rawWord in words {
                    let clean = Self.normalizeWord(rawWord)
                    guard !clean.isEmpty else { continue }
                    if customSet.insert(clean).inserted {
                        customWordsOrdered.append(clean)
                    }
                    mergedScores[clean] = max(mergedScores[clean] ?? 0.0, Self.defaultCustomZipfScore)
                }

            case .scoreMap(let scores):
                // Сортуємо за частотою, щоб зберегти детермінований пріоритет слів
                let sortedCustom = scores.sorted {
                    if $0.value != $1.value {
                        return $0.value > $1.value
                    }
                    return $0.key < $1.key
                }
                for (rawWord, score) in sortedCustom {
                    let clean = Self.normalizeWord(rawWord)
                    guard !clean.isEmpty else { continue }
                    if customSet.insert(clean).inserted {
                        customWordsOrdered.append(clean)
                    }
                    mergedScores[clean] = score
                }
            }

            // Користувацькі слова ставимо на початок списку, щоб їхні префікси мали пріоритет
            let filteredBaseTop = base.top.filter { !customSet.contains($0) }
            let mergedTop = customWordsOrdered + filteredBaseTop

            baseDictionaries[lang] = LanguageDictionary(top: mergedTop, scores: mergedScores)
        }

        self.dictionaries = baseDictionaries

        let enCount = baseDictionaries[.en]?.scores.count ?? 0
        let ukCount = baseDictionaries[.uk]?.scores.count ?? 0
        AppLogger.shared.info(.dictionary, "Завантажено словники: EN=\(enCount), UK=\(ukCount) слів")

        #if DEBUG
        print("[PBSwitcher] 📚 Словник завантажено: EN = \(enCount) слів, UK = \(ukCount) слів")
        print("[PBSwitcher] 📝 Шлях до custom_vocab.json: \(customVocabURL.path(percentEncoded: false))")
        #endif
    }

    private static func loadBaseDictionaries(
        bundle: Bundle,
        subdirectory: String?
    ) -> [LangCode: LanguageDictionary] {
        let plistURL = bundle.url(forResource: "wordfreq", withExtension: "plist")
            ?? bundle.url(forResource: "wordfreq", withExtension: "plist", subdirectory: subdirectory)

        if let plistURL {
            do {
                let data = try Data(contentsOf: plistURL)
                let rawDict = try PropertyListDecoder().decode([String: LanguageDictionary].self, from: data)
                return mapDictionaries(rawDict)
            } catch {
                AppLogger.shared.error(.dictionary, "Помилка декодування wordfreq.plist: \(error.localizedDescription)")
                #if DEBUG
                print("[PBSwitcher] ❌ Помилка декодування wordfreq.plist: \(error)")
                #endif
            }
        } else {
            AppLogger.shared.warning(.dictionary, "Файл wordfreq.plist не знайдено у бандлі")
            #if DEBUG
            print("[PBSwitcher] ❌ Файл wordfreq.plist не знайдено у бандлі (\(bundle.bundlePath))")
            #endif
        }

        // Резервна перевірка JSON
        let jsonURL = bundle.url(forResource: "wordfreq", withExtension: "json")
            ?? bundle.url(forResource: "wordfreq", withExtension: "json", subdirectory: subdirectory)

        if let jsonURL {
            do {
                let data = try Data(contentsOf: jsonURL)
                let rawDict = try JSONDecoder().decode([String: LanguageDictionary].self, from: data)
                return mapDictionaries(rawDict)
            } catch {
                AppLogger.shared.error(.dictionary, "Помилка декодування wordfreq.json: \(error.localizedDescription)")
                #if DEBUG
                print("[PBSwitcher] ❌ Помилка декодування wordfreq.json: \(error)")
                #endif
            }
        }

        return [:]
    }

    private static func loadOrCreateCustomVocab(at url: URL) -> [LangCode: CustomLanguageEntry] {
        let fm = FileManager.default
        let path = url.path(percentEncoded: false)

        if !fm.fileExists(atPath: path) {
            createDefaultCustomVocabTemplate(at: url)
            return [:]
        }

        do {
            let data = try Data(contentsOf: url)
            let raw = try JSONDecoder().decode([String: CustomLanguageEntry].self, from: data)
            var result: [LangCode: CustomLanguageEntry] = [:]
            for (key, value) in raw {
                if let lang = LangCode(rawValue: key) {
                    result[lang] = value
                }
            }
            return result
        } catch {
            AppLogger.shared.error(.dictionary, "Помилка читання custom_vocab.json: \(error.localizedDescription)")
            #if DEBUG
            print("[PBSwitcher] ❌ Помилка читання custom_vocab.json: \(error)")
            #endif
            return [:]
        }
    }

    private static func createDefaultCustomVocabTemplate(at url: URL) {
        let template = """
        {
          "en": [],
          "uk": []
        }
        """
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try template.data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            AppLogger.shared.warning(.dictionary, "Не вдалося створити шаблон custom_vocab.json: \(error.localizedDescription)")
        }
    }

    private static func mapDictionaries(_ rawDict: [String: LanguageDictionary]) -> [LangCode: LanguageDictionary] {
        var mapped: [LangCode: LanguageDictionary] = [:]
        for (key, value) in rawDict {
            if let lang = LangCode(rawValue: key) {
                mapped[lang] = value
            }
        }
        return mapped
    }

    private static func normalizeWord(_ word: String) -> String {
        word
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "ʼ", with: "'")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
    }

    public func topWords(for language: LangCode, limit: Int) -> [String] {
        guard limit > 0, let words = dictionaries[language]?.top else { return [] }
        return Array(words.prefix(limit))
    }

    public func zipfFrequency(of word: String, language: LangCode) -> Double {
        guard let scores = dictionaries[language]?.scores else { return 0.0 }
        return scores[Self.normalizeWord(word)] ?? 0.0
    }
}
