import ApplicationServices
import Carbon.HIToolbox
import Cocoa
import Foundation

// MARK: - Протоколи для macos_bridge

public protocol LayoutControlling: Sendable {
    @MainActor func switchToLanguage(_ lang: LangCode) async
}

public protocol InputContextInspecting: Sendable {
    var excludedBundleIDs: Set<String> { get }
    func getFrontmostBundleID() -> String?
    func isCarbonSecureInput() -> Bool
    func shouldBypassAutoswitch(checkCarbon: Bool) -> Bool
}

public protocol TextInjecting: Sendable {
    func isAccessibilityTrusted() -> Bool
    func captureSelectedText(inspector: any InputContextInspecting) async -> String?
    func sendBackspace()
    func sendUnicodeText(_ text: String)
}

// MARK: - Моделі подій рушія

public enum SwitchMode: String, Sendable {
    case auto
    case manual
    case selection
}

public struct SwitchEventInfo: Sendable {
    public let targetLang: LangCode
    public let original: String
    public let converted: String
    public let mode: SwitchMode
}

private enum EngineKey: Equatable, Sendable {
    case backspace
    case whitespaceBreak(Character)
    case nonLayoutBreak
    case navigationReset
    case f6
    case f12
    case character(Character)
    case other
}

private struct KeyStrokeEvent: Sendable {
    let key: EngineKey
    let timestamp: TimeInterval
    let resetOnly: Bool
}

private struct LastConversionRecord: Sendable {
    let originalToken: String
    let convertedToken: String
    let sourceLang: LangCode
    let targetLang: LangCode
    let timestamp: TimeInterval
}

// MARK: - Нативний перехоплювач CGEventTap

private enum RawTapEvent: Sendable {
    case keyDown(keyCode: CGKeyCode, flags: CGEventFlags, unicode: String?)
    case flagsChanged(keyCode: CGKeyCode, flags: CGEventFlags)
}

nonisolated private final class GlobalKeyTapMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?

    private let continuation: AsyncStream<RawTapEvent>.Continuation

    init(continuation: AsyncStream<RawTapEvent>.Continuation) {
        self.continuation = continuation
    }

    func start() {
        lock.lock()
        guard tapThread == nil else {
            lock.unlock()
            return
        }

        let thread = Thread { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.eventTap = nil
                self.runLoopSource = nil
                self.tapRunLoop = nil
                self.tapThread = nil
                self.lock.unlock()
            }

            let mask: CGEventMask =
                (1 << CGEventType.keyDown.rawValue) |
                (1 << CGEventType.flagsChanged.rawValue)

            let userInfo = Unmanaged.passUnretained(self).toOpaque()

            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let monitor = Unmanaged<GlobalKeyTapMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    monitor.handle(type: type, event: event)
                    return Unmanaged.passUnretained(event)
                },
                userInfo: userInfo
            ) else {
                AppLogger.shared.error(.engine, "Не вдалося створити CGEventTap (перевірте права Accessibility)")
                return
            }

            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            let currentLoop = CFRunLoopGetCurrent()

            self.lock.lock()
            self.eventTap = tap
            self.runLoopSource = source
            self.tapRunLoop = currentLoop
            self.lock.unlock()

            CFRunLoopAddSource(currentLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "AutoSwitcherCGEventTap"
        thread.qualityOfService = .userInteractive
        self.tapThread = thread
        lock.unlock()

        thread.start()
    }

    func stop() {
        lock.lock()
        let tap = eventTap
        let source = runLoopSource
        let loop = tapRunLoop
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        lock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let loop, let source {
            CFRunLoopRemoveSource(loop, source, .commonModes)
        }
        if let loop {
            CFRunLoopStop(loop)
        }
        continuation.finish()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            AppLogger.shared.warning(.engine, "CGEventTap тимчасово відключено системою, виконується повторне ввімкнення")
            #if DEBUG
            print("[PBSwitcher] ⚠️ CGEventTap disabled by system: \(type.rawValue)")
            #endif
            lock.lock()
            let tap = eventTap
            lock.unlock()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        // Миттєво відсіюємо наші власні згенеровані натискання
        if event.getIntegerValueField(.eventSourceUserData) == QuartzTextInjector.syntheticEventTag {
            return
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        if type == .flagsChanged {
            continuation.yield(.flagsChanged(keyCode: keyCode, flags: flags))
        } else if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return
            }
            let unicodeString = extractUnicodeString(from: event)
            continuation.yield(.keyDown(keyCode: keyCode, flags: flags, unicode: unicodeString))
        }
    }

    private func extractUnicodeString(from event: CGEvent) -> String? {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

// MARK: - Основний рушій (Swift Actor)

public actor AsyncKeyboardEngine {
    private static let evaluationLengths: Set<Int> = [3, 4]
    private static let backspaceDelayNs: UInt64 = 5_000_000       // 0.005s
    private static let layoutSwitchDelayNs: UInt64 = 20_000_000   // 0.02s
    private static let doubleTapWindowSec: TimeInterval = 0.35

    private static let allLayoutChars: Set<Character> =
        Set(PrefixLanguageDetector.enLayout).union(PrefixLanguageDetector.ukLayout)

    private let detector: PrefixLanguageDetector
    private let layoutController: any LayoutControlling
    private let contextInspector: any InputContextInspecting
    private let injector: any TextInjecting
    private let onSwitchCallback: @Sendable (SwitchEventInfo) -> Void
    private let onPermissionMissingCallback: (@Sendable () -> Void)?

    private var enabled: Bool
    private var hotkeyPreset: HotkeyPreset
    private var currentBundleID: String?

    private var buffer: [Character] = []
    private var lastWordBuffer: [Character] = []
    private var trailingBreakChar: Character?
    private var trailingBreakCount: Int = 0
    private var lastConversion: LastConversionRecord?
    private var suppressAutoForCurrentWord = false

    private var isInjecting = false
    private var userInputDuringInjection = false
    private var activeModifierKeyCodes: Set<CGKeyCode> = []
    private var lastCleanModTs: TimeInterval = 0
    private var modUsedWithOtherKey = false
    private var lastAlphaShiftState: Bool?

    private var monitor: GlobalKeyTapMonitor?
    private var consumerTask: Task<Void, Never>?

    private func debug(_ msg: String) {
        #if DEBUG
        print("[PBSwitcher] \(msg)")
        #endif
    }

    public init(
        detector: PrefixLanguageDetector,
        layoutController: any LayoutControlling,
        contextInspector: any InputContextInspecting,
        injector: any TextInjecting,
        hotkeyPreset: HotkeyPreset,
        enabled: Bool,
        onSwitchCallback: @escaping @Sendable (SwitchEventInfo) -> Void,
        onPermissionMissingCallback: (@Sendable () -> Void)? = nil
    ) {
        self.detector = detector
        self.layoutController = layoutController
        self.contextInspector = contextInspector
        self.injector = injector
        self.hotkeyPreset = hotkeyPreset
        self.enabled = enabled
        self.currentBundleID = contextInspector.getFrontmostBundleID()
        self.onSwitchCallback = onSwitchCallback
        self.onPermissionMissingCallback = onPermissionMissingCallback
    }

    deinit {
        monitor?.stop()
        consumerTask?.cancel()
    }

    // MARK: - Керування станом

    public func setEnabled(_ value: Bool) {
        enabled = value
        if !value {
            clearAllBuffers()
        }
    }

    public func setHotkeyPreset(_ preset: HotkeyPreset) {
        hotkeyPreset = preset
        lastCleanModTs = 0
        modUsedWithOtherKey = false
        lastAlphaShiftState = nil
    }

    public func notifyActiveAppChanged(bundleID: String?) {
        AppLogger.shared.info(.engine, "Активна програма: \(bundleID ?? "невідомо")")
        currentBundleID = bundleID
        clearAllBuffers()
    }

    public func start() {
        guard monitor == nil else { return }

        let (stream, continuation) = AsyncStream.makeStream(of: RawTapEvent.self)
        let tap = GlobalKeyTapMonitor(continuation: continuation)
        self.monitor = tap

        self.consumerTask = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                switch event {
                case .keyDown(let keyCode, let flags, let unicode):
                    await self.handleKeyDown(keyCode: keyCode, flags: flags, unicode: unicode)
                case .flagsChanged(let keyCode, let flags):
                    await self.handleFlagsChanged(keyCode: keyCode, flags: flags)
                }
            }
        }

        tap.start()
    }

    public func stop() {
        monitor?.stop()
        monitor = nil
        consumerTask?.cancel()
        consumerTask = nil
        clearAllBuffers()
    }

    public func forceConvertWordOrSelection() async {
        await executeForceConversion()
    }

    private func clearAllBuffers() {
        buffer.removeAll()
        lastWordBuffer.removeAll()
        trailingBreakChar = nil
        trailingBreakCount = 0
        lastConversion = nil
        suppressAutoForCurrentWord = false
    }

    // MARK: - Обробка системних клавіш

    private func handleFlagsChanged(keyCode: CGKeyCode, flags: CGEventFlags) async {
        let now = ProcessInfo.processInfo.systemUptime

        // Caps Lock у macOS генерує flagsChanged і при натисканні, і при відпусканні.
        // Реагуємо лише на реальну зміну стану .maskAlphaShift (один раз за натискання).
        if keyCode == CGKeyCode(kVK_CapsLock) {
            let currentAlphaShift = flags.contains(.maskAlphaShift)
            let changed = (lastAlphaShiftState != currentAlphaShift)
            lastAlphaShiftState = currentAlphaShift

            if changed {
                modUsedWithOtherKey = true
                lastCleanModTs = 0
                if hotkeyPreset == .keyCapsLock && !isInjecting {
                    await executeForceConversion()
                }
            }
            return
        }

        let isPressed = isModifierPressed(keyCode: keyCode, flags: flags)
        let targetCodes = doubleTapKeyCodes(for: hotkeyPreset)

        if isPressed {
            if targetCodes.contains(keyCode) {
                let otherMods = activeModifierKeyCodes.subtracting(targetCodes)
                if otherMods.isEmpty {
                    modUsedWithOtherKey = false
                }
            } else {
                modUsedWithOtherKey = true
                lastCleanModTs = 0
            }
            activeModifierKeyCodes.insert(keyCode)
        } else {
            activeModifierKeyCodes.remove(keyCode)

            if targetCodes.contains(keyCode) && !isInjecting {
                if !modUsedWithOtherKey && activeModifierKeyCodes.isEmpty {
                    if (now - lastCleanModTs) <= Self.doubleTapWindowSec {
                        lastCleanModTs = 0
                        await executeForceConversion()
                    } else {
                        lastCleanModTs = now
                    }
                } else {
                    lastCleanModTs = 0
                }
            }
        }
    }

    private func handleKeyDown(keyCode: CGKeyCode, flags: CGEventFlags, unicode: String?) async {
        let now = ProcessInfo.processInfo.systemUptime

        // Будь-яка звичайна клавіша перериває ланцюжок подвійного натискання модифікатора
        modUsedWithOtherKey = true
        lastCleanModTs = 0

        let activeModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        if let singleTarget = singleTapKeyCode(for: hotkeyPreset),
           keyCode == singleTarget,
           flags.intersection(activeModifiers).isEmpty {
            await executeForceConversion()
            return
        }

        // Якщо затиснутий Command, Control або Option — скидаємо буфер слова
        let commandModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
        if !flags.intersection(commandModifiers).isEmpty {
            await processStroke(KeyStrokeEvent(key: .other, timestamp: now, resetOnly: true))
            return
        }

        let mappedKey = mapKey(keyCode: keyCode, unicode: unicode)
        await processStroke(KeyStrokeEvent(key: mappedKey, timestamp: now, resetOnly: false))
    }

    // MARK: - Конвеєр обробки символів

    private func processStroke(_ event: KeyStrokeEvent) async {
        if isInjecting {
            userInputDuringInjection = true
        }

        guard enabled, !event.resetOnly else {
            clearAllBuffers()
            return
        }

        if let bundleID = currentBundleID,
           contextInspector.excludedBundleIDs.contains(bundleID) || contextInspector.isCarbonSecureInput() {
            clearAllBuffers()
            return
        }

        switch event.key {
        case .navigationReset:
            clearAllBuffers()

        case .backspace:
            if !buffer.isEmpty {
                buffer.removeLast()
            } else if trailingBreakCount > 0 {
                trailingBreakCount -= 1
                if trailingBreakCount == 0 {
                    trailingBreakChar = nil
                    buffer = lastWordBuffer
                    lastWordBuffer.removeAll()
                }
            } else if !lastWordBuffer.isEmpty {
                buffer = lastWordBuffer
                lastWordBuffer.removeAll()
            }

        case .whitespaceBreak(let breakChar):
            if !buffer.isEmpty {
                lastWordBuffer = buffer
                buffer.removeAll()
                trailingBreakChar = breakChar
                trailingBreakCount = 1
            } else if !lastWordBuffer.isEmpty {
                trailingBreakCount += 1
            }
            suppressAutoForCurrentWord = false

        case .nonLayoutBreak:
            if !buffer.isEmpty {
                lastWordBuffer = buffer
                buffer.removeAll()
                trailingBreakChar = nil
                trailingBreakCount = 0
            }
            suppressAutoForCurrentWord = false

        case .character(let ch):
            if buffer.isEmpty {
                lastWordBuffer.removeAll()
                trailingBreakChar = nil
                trailingBreakCount = 0
                lastConversion = nil
            }

            buffer.append(ch)
            debug("char='\(ch)' | buf='\(String(buffer))' (len=\(buffer.count)) | suppress=\(suppressAutoForCurrentWord) | injecting=\(isInjecting)")

            if !suppressAutoForCurrentWord && Self.evaluationLengths.contains(buffer.count) {
                await processAutoEvaluation()
            }

        case .f6, .f12, .other:
            break
        }
    }

    private func processAutoEvaluation() async {
        guard !isInjecting, !buffer.isEmpty else {
            debug("skip eval: isInjecting=\(isInjecting), empty=\(buffer.isEmpty)")
            return
        }

        if contextInspector.shouldBypassAutoswitch(checkCarbon: false) {
            debug("bypass: AX/excluded app")
            clearAllBuffers()
            return
        }

        let currentToken = String(buffer)
        guard let decision = detector.evaluateSwitch(for: currentToken) else {
            debug("no switch decision for '\(currentToken)' (src=\(String(describing: detector.detectSourceLanguage(in: currentToken))))")
            return
        }

        await replaceTextAndSwitch(
            original: currentToken,
            converted: decision.convertedText,
            sourceLang: decision.source,
            targetLang: decision.target,
            mode: .auto
        )
    }

    private func executeForceConversion() async {
        guard !isInjecting else { return }

        guard injector.isAccessibilityTrusted() else {
            onPermissionMissingCallback?()
            return
        }

        if contextInspector.isCarbonSecureInput() {
            clearAllBuffers()
            return
        }

        // 1. Перевіряємо виділений текст
        if let selectedText = await injector.captureSelectedText(inspector: contextInspector),
           !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let forcedSel = detector.forceTransliterate(selectedText) {
            await replaceSelectedTextAndSwitch(
                original: selectedText,
                converted: forcedSel.convertedText,
                targetLang: forcedSel.target
            )
            return
        }

        // 2. Працюємо з поточним або попереднім словом у буфері
        let targetBuffer = !buffer.isEmpty ? buffer : lastWordBuffer
        guard !targetBuffer.isEmpty else { return }

        let currentText = String(targetBuffer)

        // Відкат останньої автоматичної конвертації + дописаного хвоста
        if let rec = lastConversion, currentText.hasPrefix(rec.convertedToken) {
            let tailStart = currentText.index(currentText.startIndex, offsetBy: rec.convertedToken.count)
            let tail = String(currentText[tailStart...])
            var revertedTail = ""

            if !tail.isEmpty {
                let tailRes = detector.forceTransliterate(tail, preferredSource: rec.targetLang)
                revertedTail = tailRes?.convertedText ?? tail
            }

            let restoredText = rec.originalToken + revertedTail
            lastConversion = nil
            suppressAutoForCurrentWord = true

            await replaceTextAndSwitch(
                original: currentText,
                converted: restoredText,
                sourceLang: rec.targetLang,
                targetLang: rec.sourceLang,
                mode: .manual
            )
            return
        }

        // Звичайна ручна транслітерація
        guard let forced = detector.forceTransliterate(currentText) else { return }
        lastConversion = nil
        suppressAutoForCurrentWord = true

        await replaceTextAndSwitch(
            original: currentText,
            converted: forced.convertedText,
            sourceLang: forced.source,
            targetLang: forced.target,
            mode: .manual
        )
    }

    private func replaceSelectedTextAndSwitch(
        original: String,
        converted: String,
        targetLang: LangCode
    ) async {
        isInjecting = true
        userInputDuringInjection = false
        defer {
            isInjecting = false
        }

        await layoutController.switchToLanguage(targetLang)
        try? await Task.sleep(nanoseconds: Self.layoutSwitchDelayNs)

        injector.sendUnicodeText(converted)
        clearAllBuffers()

        onSwitchCallback(SwitchEventInfo(
            targetLang: targetLang,
            original: original,
            converted: converted,
            mode: .selection
        ))
    }

    private func replaceTextAndSwitch(
        original: String,
        converted: String,
        sourceLang: LangCode,
        targetLang: LangCode,
        mode: SwitchMode
    ) async {
        guard injector.isAccessibilityTrusted() else {
            onPermissionMissingCallback?()
            return
        }
        AppLogger.shared.info(.engine, "Конвертація [\(mode.rawValue)]: \(sourceLang.rawValue) -> \(targetLang.rawValue) (довжина: \(original.count))")

        isInjecting = true
        userInputDuringInjection = false
        defer {
            isInjecting = false
        }

        // 1. Спочатку перемикаємо розкладку, щоб у системи був час застосувати її до наступних натискань
        await layoutController.switchToLanguage(targetLang)

        let hadSingleTrailingBreak = buffer.isEmpty && !lastWordBuffer.isEmpty && trailingBreakCount == 1
        let preservedBreakChar = hadSingleTrailingBreak ? trailingBreakChar : nil
        let deleteCount = original.count + (hadSingleTrailingBreak ? 1 : 0)

        // 2. Стираємо помилково набрані символи
        for _ in 0..<deleteCount {
            injector.sendBackspace()
            try? await Task.sleep(nanoseconds: Self.backspaceDelayNs)
        }

        // 3. Додаткова пауза для синхронізації розкладки перед вставкою тексту
        try? await Task.sleep(nanoseconds: Self.layoutSwitchDelayNs)

        let textToInject: String = if let breakChar = preservedBreakChar {
            "\(converted)\(breakChar)"
        } else {
            converted
        }
        injector.sendUnicodeText(textToInject)

        if userInputDuringInjection {
            // Користувач продовжив друк під час вставки — не перезаписуємо буфер застарілим словом
            clearAllBuffers()
        } else if hadSingleTrailingBreak {
            lastWordBuffer = Array(converted)
            buffer.removeAll()
        } else {
            buffer = Array(converted)
            lastWordBuffer.removeAll()
            trailingBreakChar = nil
            trailingBreakCount = 0
        }

        if mode == .auto {
            suppressAutoForCurrentWord = true
            lastConversion = LastConversionRecord(
                originalToken: original,
                convertedToken: converted,
                sourceLang: sourceLang,
                targetLang: targetLang,
                timestamp: ProcessInfo.processInfo.systemUptime
            )
        }

        onSwitchCallback(SwitchEventInfo(
            targetLang: targetLang,
            original: original,
            converted: converted,
            mode: mode
        ))
    }

    // MARK: - Мапінг віртуальних кодів клавіш macOS (Carbon HIToolbox)

    private func mapKey(keyCode: CGKeyCode, unicode: String?) -> EngineKey {
        switch Int(keyCode) {
        case kVK_Delete:
            return .backspace
        case kVK_Space:
            return .whitespaceBreak(" ")
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return .whitespaceBreak("\n")
        case kVK_Tab:
            return .whitespaceBreak("\t")
        case kVK_Escape, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_ForwardDelete, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            return .navigationReset
        case kVK_F6:
            return .f6
        case kVK_F12:
            return .f12
        default:
            guard let unicode, unicode.count == 1, let ch = unicode.first else {
                return .other
            }
            if ch.isWhitespace {
                return .whitespaceBreak(ch)
            }
            if Self.allLayoutChars.contains(ch) {
                return .character(ch)
            }
            return .nonLayoutBreak
        }
    }

    private func singleTapKeyCode(for preset: HotkeyPreset) -> CGKeyCode? {
        switch preset {
        case .keyF6: return CGKeyCode(kVK_F6)
        case .keyF12: return CGKeyCode(kVK_F12)
        default: return nil
        }
    }

    private func doubleTapKeyCodes(for preset: HotkeyPreset) -> Set<CGKeyCode> {
        switch preset {
        case .doubleShift:
            return [CGKeyCode(kVK_Shift), CGKeyCode(kVK_RightShift)]
        case .doubleAlt:
            return [CGKeyCode(kVK_Option), CGKeyCode(kVK_RightOption)]
        case .doubleCtrl:
            return [CGKeyCode(kVK_Control), CGKeyCode(kVK_RightControl)]
        case .doubleCmd:
            return [CGKeyCode(kVK_Command), CGKeyCode(kVK_RightCommand)]
        default:
            return []
        }
    }

    private func isModifierPressed(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        switch Int(keyCode) {
        case kVK_Shift, kVK_RightShift:
            return flags.contains(.maskShift)
        case kVK_Option, kVK_RightOption:
            return flags.contains(.maskAlternate)
        case kVK_Control, kVK_RightControl:
            return flags.contains(.maskControl)
        case kVK_Command, kVK_RightCommand:
            return flags.contains(.maskCommand)
        default:
            return false
        }
    }
}
