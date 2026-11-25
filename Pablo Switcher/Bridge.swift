import ApplicationServices
import Carbon.HIToolbox
import Cocoa
import Foundation

public enum MacOSDefaults {
    public static let excludedBundleIDs: Set<String> = [
        // Термінали
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        // Редактори коду та IDE
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "dev.zed.Zed",
        "com.sublimetext.4",
        "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce",
        "com.jetbrains.intellij",
        "com.apple.dt.Xcode",
        // Менеджери паролів та безпека
        "com.1password.1password",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.apple.Passwords",
        "com.apple.keychainaccess"
    ]
}

// MARK: - Ін'єктор клавіш та тексту

nonisolated public final class QuartzTextInjector: TextInjecting, @unchecked Sendable {
    public static let syntheticEventTag: Int64 = 0x5042_5357
    private let eventSource: CGEventSource?

    public init() {
        self.eventSource = CGEventSource(stateID: .privateState)
    }

    public func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    public func sendBackspace() {
        let deleteKey = CGKeyCode(kVK_Delete)
        postKeyEvent(virtualKey: deleteKey, keyDown: true)
        postKeyEvent(virtualKey: deleteKey, keyDown: false)
    }

    public func sendCmdC() {
        let cKey = CGKeyCode(kVK_ANSI_C)
        postKeyEvent(virtualKey: cKey, keyDown: true, flags: .maskCommand)
        postKeyEvent(virtualKey: cKey, keyDown: false, flags: .maskCommand)
    }

    public func captureSelectedText(inspector: any InputContextInspecting) async -> String? {
        if let axInspector = inspector as? MacOSInputContextInspector,
           let axSelected = axInspector.getAXSelectedText(),
           !axSelected.isEmpty {
            return axSelected
        }

        // Робота з NSPasteboard строго на MainActor із повним бекапом усіх типів даних (зображення, файли, RTF, текст)
        let (oldChangeCount, backupItems) = await MainActor.run {
            let pasteboard = NSPasteboard.general
            return (pasteboard.changeCount, Self.snapshotPasteboard(pasteboard))
        }

        sendCmdC()

        var copiedText: String?
        let deadline = ProcessInfo.processInfo.systemUptime + 0.12

        while ProcessInfo.processInfo.systemUptime < deadline {
            let result: (changed: Bool, text: String?) = await MainActor.run {
                let pasteboard = NSPasteboard.general
                guard pasteboard.changeCount != oldChangeCount else {
                    return (false, nil)
                }
                return (true, pasteboard.string(forType: .string))
            }

            if result.changed {
                if let raw = result.text, !raw.isEmpty {
                    copiedText = raw
                }
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10 ms
        }

        if copiedText != nil {
            await MainActor.run {
                Self.restorePasteboard(NSPasteboard.general, from: backupItems)
            }
        }

        return copiedText
    }

    public func sendUnicodeText(_ text: String) {
        guard !text.isEmpty else { return }

        // CGEvent.keyboardSetUnicodeString підтримує до 20 UTF-16 одиниць за одну подію.
        // Надсилаємо чанками до 16 одиниць, не розриваючи сурогатні пари.
        var chunk: [UniChar] = []
        chunk.reserveCapacity(16)

        for scalar in text.unicodeScalars {
            let utf16 = scalar.utf16
            if chunk.count + utf16.count > 16 {
                postUnicodeChunk(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
            chunk.append(contentsOf: utf16)
        }

        if !chunk.isEmpty {
            postUnicodeChunk(chunk)
        }
    }

    private func postUnicodeChunk(_ units: [UniChar]) {
        var buffer = units
        guard let downEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
              let upEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) else {
            return
        }

        downEvent.flags = []
        downEvent.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
        downEvent.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
        downEvent.post(tap: .cghidEventTap)

        upEvent.flags = []
        upEvent.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
        upEvent.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
        upEvent.post(tap: .cghidEventTap)
    }

    private func postKeyEvent(virtualKey: CGKeyCode, keyDown: Bool, flags: CGEventFlags = []) {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: virtualKey, keyDown: keyDown) else {
            return
        }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Бекап та відновлення буфера обміну

    private typealias PasteboardItemSnapshot = [(type: NSPasteboard.PasteboardType, data: Data)]

    @MainActor
    private static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [PasteboardItemSnapshot] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type: type, data: data)
            }
        }
    }

    @MainActor
    private static func restorePasteboard(_ pasteboard: NSPasteboard, from snapshots: [PasteboardItemSnapshot]) {
        pasteboard.clearContents()
        guard !snapshots.isEmpty else { return }

        let restoredItems: [NSPasteboardItem] = snapshots.compactMap { snapshot in
            guard !snapshot.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for entry in snapshot {
                item.setData(entry.data, forType: entry.type)
            }
            return item
        }

        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}

// MARK: - Інспектор активного контексту та безпеки

nonisolated public final class MacOSInputContextInspector: InputContextInspecting, @unchecked Sendable {
    public let excludedBundleIDs: Set<String>
    private let systemWideElement: AXUIElement

    public init(excludedBundleIDs: Set<String> = MacOSDefaults.excludedBundleIDs) {
        self.excludedBundleIDs = excludedBundleIDs
        self.systemWideElement = AXUIElementCreateSystemWide()
    }

    public func isCarbonSecureInput() -> Bool {
        IsSecureEventInputEnabled()
    }

    public func getFrontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    public func getAXSelectedText() -> String? {
        guard AXIsProcessTrusted(),
              let focusedElement = copyFocusedElement() else {
            return nil
        }

        var selectedValue: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        )

        guard err == .success,
              let text = selectedValue as? String,
              !text.isEmpty else {
            return nil
        }

        return text
    }

    public func shouldBypassAutoswitch(checkCarbon: Bool = true) -> Bool {
        if checkCarbon && isCarbonSecureInput() {
            return true
        }

        if let frontBundleID = getFrontmostBundleID(),
           excludedBundleIDs.contains(frontBundleID) {
            return true
        }

        guard AXIsProcessTrusted(),
              let focusedElement = copyFocusedElement() else {
            return false
        }

        var pid: pid_t = 0
        if AXUIElementGetPid(focusedElement, &pid) == .success,
           let focusedApp = NSRunningApplication(processIdentifier: pid),
           let focusedBundleID = focusedApp.bundleIdentifier,
           excludedBundleIDs.contains(focusedBundleID) {
            return true
        }

        if attributeEquals(focusedElement, attribute: kAXSubroleAttribute, expected: kAXSecureTextFieldSubrole) {
            return true
        }

        return false
    }

    private func copyFocusedElement() -> AXUIElement? {
        var elementRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &elementRef
        )
        guard err == .success,
              let elementRef,
              CFGetTypeID(elementRef) == AXUIElementGetTypeID() else {
            return nil
        }
        return (elementRef as! AXUIElement)
    }

    private func attributeEquals(_ element: AXUIElement, attribute: String, expected: String) -> Bool {
        var valueRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef)
        guard err == .success, let stringValue = valueRef as? String else {
            return false
        }
        return stringValue == expected
    }
}

// MARK: - Контролер перемикання розкладки

public final class MacOSLayoutController: LayoutControlling, Sendable {
    public init() {}

    @MainActor
    public func switchToLanguage(_ lang: LangCode) async {
        let preferredIDs: [String] = switch lang {
        case .en:
            ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]
        case .uk:
            ["com.apple.keylayout.Ukrainian-PC", "com.apple.keylayout.Ukrainian"]
        }

        let filter: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true
        ]

        guard let listUnmanaged = TISCreateInputSourceList(filter as CFDictionary, false),
              let sources = listUnmanaged.takeRetainedValue() as? [TISInputSource] else {
            return
        }

        let targetSource = preferredIDs.lazy.compactMap { targetID in
            sources.first { self.sourceID(of: $0) == targetID }
        }.first ?? sources.first { self.matchesLanguage($0, code: lang.rawValue) }

        guard let targetSource else {
            AppLogger.shared.warning(.layout, "Не знайдено доступної розкладки для мови: \(lang.rawValue)")
            return
        }

        // Якщо розкладка вже активна — не викликаємо зайвий TISSelectInputSource
        if let currentUnmanaged = TISCopyCurrentKeyboardInputSource() {
            let currentSource = currentUnmanaged.takeRetainedValue()
            if sourceID(of: currentSource) == sourceID(of: targetSource) {
                return
            }
        }

        let status = TISSelectInputSource(targetSource)
        if status != noErr {
            AppLogger.shared.error(.layout, "Помилка перемикання розкладки на \(lang.rawValue): OSStatus=\(status)")
        }
    }

    @MainActor
    private func sourceID(of source: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    @MainActor
    private func matchesLanguage(_ source: TISInputSource, code: String) -> Bool {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
              let langs = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String] else {
            return false
        }
        return langs.contains { $0.hasPrefix(code) }
    }
}
