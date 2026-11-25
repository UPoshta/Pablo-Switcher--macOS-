//
//  AppLogger.swift
//  Pablo Switcher
//
//  Created by Serhii Meleshchuk on 25.11.2026.
//

import Foundation
import OSLog

public enum LogCategory: String, CaseIterable, Sendable {
    case app = "App"
    case engine = "Engine"
    case layout = "Layout"
    case dictionary = "Dictionary"
    case permissions = "Permissions"
    case settings = "Settings"
}

private enum LogLevel: String {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

nonisolated public final class AppLogger: Sendable {
    public static let shared = AppLogger()

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.pabloswitcher.app"
    private static let maxLogSizeBytes: UInt64 = 1_048_576 // 1 МБ

    private let queue = DispatchQueue(label: "com.pabloswitcher.logger", qos: .utility)
    private let logFileURL: URL
    private let loggers: [LogCategory: Logger]

    // Доступ до цих полів відбувається виключно всередині серійної черги `queue`
    private nonisolated(unsafe) var fileHandle: FileHandle?
    private nonisolated(unsafe) let dateFormatter: ISO8601DateFormatter

    private init() {
        let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Pablo Switcher"
        let logsDir = URL.libraryDirectory
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)

        self.logFileURL = logsDir.appendingPathComponent("pablo-switcher.log")

        var cachedLoggers: [LogCategory: Logger] = [:]
        for category in LogCategory.allCases {
            cachedLoggers[category] = Logger(subsystem: Self.subsystem, category: category.rawValue)
        }
        self.loggers = cachedLoggers

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.dateFormatter = formatter

        queue.async { [self] in
            try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
            self.rotateIfNeeded()
            self.openFileHandle()
        }
    }

    deinit {
        try? fileHandle?.close()
    }

    public var currentLogURL: URL {
        logFileURL
    }

    public func info(_ category: LogCategory, _ message: String) {
        write(level: .info, category: category, message: message)
    }

    public func warning(_ category: LogCategory, _ message: String) {
        write(level: .warning, category: category, message: message)
    }

    public func error(_ category: LogCategory, _ message: String) {
        write(level: .error, category: category, message: message)
    }

    private func write(level: LogLevel, category: LogCategory, message: String) {
        if let logger = loggers[category] {
            switch level {
            case .info:
                logger.info("\(message, privacy: .public)")
            case .warning:
                logger.warning("\(message, privacy: .public)")
            case .error:
                logger.error("\(message, privacy: .public)")
            }
        }

        // Фіксуємо час одразу в момент виклику, а не коли дійде черга запису на диск
        let now = Date()

        queue.async { [self] in
            let timestamp = self.dateFormatter.string(from: now)
            let line = "[\(timestamp)] [\(level.rawValue)] [\(category.rawValue)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            self.rotateIfNeeded()

            if self.fileHandle == nil {
                self.openFileHandle()
            }

            do {
                try self.fileHandle?.write(contentsOf: data)
            } catch {
                // Якщо файл видалили ззовні під час роботи програми — перевідкриваємо
                self.openFileHandle()
                try? self.fileHandle?.write(contentsOf: data)
            }
        }
    }

    private func openFileHandle() {
        try? fileHandle?.close()
        fileHandle = nil

        let path = logFileURL.path(percentEncoded: false)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }

        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            _ = try? handle.seekToEnd()
            fileHandle = handle
        }
    }

    private func rotateIfNeeded() {
        let path = logFileURL.path(percentEncoded: false)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64,
              size >= Self.maxLogSizeBytes else {
            return
        }

        try? fileHandle?.close()
        fileHandle = nil

        let backupURL = logFileURL.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: logFileURL, to: backupURL)

        openFileHandle()
    }
}
