import AppKit
import Observation
import ServiceManagement

@MainActor
private final class WeakAppStoreBox: Sendable {
    weak var store: AppStore?
}

@MainActor
@Observable
public final class AppStore {
    public var settings: AppSettings
    public let i18n: XMLI18nManager

    public private(set) var isAccessibilityTrusted: Bool = false
    public private(set) var switchCount: Int = 0
    public private(set) var lastSwitchInfo: SwitchEventInfo?
    public var isAutostartEnabled: Bool = false
    public var showAutostartErrorAlert: Bool = false

    private let engine: AsyncKeyboardEngine
    private let injector: QuartzTextInjector
    private var workspaceObserver: NSObjectProtocol?
    private var permissionPollTask: Task<Void, Never>?
    private var settingsSyncTask: Task<Void, Never>?
    private var didPromptRestartForAX = false

    private static let whitespaceRegex = /\s+/

    public init(frequencyProvider: any WordFrequencyProvider) {
        
        let loadedSettings = AppSettings.load()
        let i18nManager = XMLI18nManager()
        i18nManager.language = loadedSettings.uiLanguage

        self.settings = loadedSettings
        self.i18n = i18nManager

        let detector = PrefixLanguageDetector(minPrefixLength: 3, frequencyProvider: frequencyProvider)
        let layoutController = MacOSLayoutController()
        let contextInspector = MacOSInputContextInspector()
        let textInjector = QuartzTextInjector()
        self.injector = textInjector

        self.isAccessibilityTrusted = textInjector.isAccessibilityTrusted()
        self.isAutostartEnabled = (SMAppService.mainApp.status == .enabled)

        let weakBox = WeakAppStoreBox()
                let engineInstance = AsyncKeyboardEngine(
                    detector: detector,
                    layoutController: layoutController,
                    contextInspector: contextInspector,
                    injector: textInjector,
                    hotkeyPreset: loadedSettings.hotkeyPreset,
                    enabled: loadedSettings.autoSwitchEnabled,
                    onSwitchCallback: { info in
                        Task { @MainActor in
                            weakBox.store?.handleSwitchEvent(info)
                        }
                    },
                    onPermissionMissingCallback: {
                        Task { @MainActor in
                            weakBox.store?.refreshAccessibilityStatus()
                        }
                    }
                )
                self.engine = engineInstance
                weakBox.store = self
        subscribeToWorkspaceNotifications()

        Task {
            await engineInstance.start()
        }
        AppLogger.shared.info(.app, "Запуск програми. Accessibility=\(isAccessibilityTrusted), Autostart=\(isAutostartEnabled)")
    }

    // MARK: - Обчислювані заголовки меню (реактивні)

    public var statusTitle: String {
        if !isAccessibilityTrusted {
            return i18n.t("status_need_ax")
        }
        return settings.autoSwitchEnabled ? i18n.t("status_active") : i18n.t("status_paused")
    }

    public var lastActionTitle: String {
        guard let info = lastSwitchInfo else {
            return i18n.t("last_action_none")
        }
        let langBadge = (info.targetLang == .uk) ? "UA" : "EN"
        let modeStr = i18n.t("mode_\(info.mode.rawValue)")

        let cleanOrig = info.original.replacing(Self.whitespaceRegex, with: " ")
        let cleanConv = info.converted.replacing(Self.whitespaceRegex, with: " ")

        let shortOrig = cleanOrig.count <= 18 ? cleanOrig : String(cleanOrig.prefix(15)) + "…"
        let shortConv = cleanConv.count <= 18 ? cleanConv : String(cleanConv.prefix(15)) + "…"

        return i18n.t("last_action_fmt", args: [
            "mode": modeStr,
            "orig": shortOrig,
            "conv": shortConv,
            "lang": langBadge
        ])
    }

    public var statsTitle: String {
        i18n.t("stats_fmt", args: ["count": switchCount])
    }

    public var toggleTitle: String {
        settings.autoSwitchEnabled ? i18n.t("menu_pause") : i18n.t("menu_resume")
    }

    public var forceConvertTitle: String {
        let hotkeyStr = i18n.hotkeyLabel(for: settings.hotkeyPreset)
        return i18n.t("menu_force_convert", args: ["hotkey": hotkeyStr])
    }

    // MARK: - Дії користувача

    public func refreshAccessibilityStatus() {
        let wasTrusted = isAccessibilityTrusted
        let nowTrusted = injector.isAccessibilityTrusted()
        isAccessibilityTrusted = nowTrusted

        // Якщо доступ щойно надали (перехід false -> true), пропонуємо перезапуск
        if !wasTrusted && nowTrusted {
            permissionPollTask?.cancel()
            permissionPollTask = nil
            promptRestartAfterPermissionGranted()
        }
    }

    public func refreshAutostartStatus() {
        isAutostartEnabled = (SMAppService.mainApp.status == .enabled)
    }

    public func openAccessibilitySettings() {
        refreshAccessibilityStatus()
        guard !isAccessibilityTrusted else { return }

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }

        startPermissionPolling()
    }

    private func startPermissionPolling() {
        permissionPollTask?.cancel()
        permissionPollTask = Task { [weak self] in
            // Перевіряємо статус кожну секунду протягом 2 хвилин, поки відкриті налаштування
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.refreshAccessibilityStatus()
                if self.isAccessibilityTrusted {
                    return
                }
            }
        }
    }

    private func promptRestartAfterPermissionGranted() {
        guard !didPromptRestartForAX else { return }
        didPromptRestartForAX = true

        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSImage(named: NSImage.applicationIconName)
        alert.messageText = i18n.t("ax_restart_title")
        alert.informativeText = i18n.t("ax_restart_body")
        alert.addButton(withTitle: i18n.t("ax_restart_now"))
        alert.addButton(withTitle: i18n.t("ax_restart_later"))
        alert.window.level = .floating

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            restartApp()
        }
    }

    public func restartApp() {
        cleanupObservers()

        let bundleURL = Bundle.main.bundleURL
        Task {
            await engine.stop()

            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { app, error in
                Task { @MainActor in
                    if app != nil {
                        NSApplication.shared.terminate(nil)
                    } else {
                        AppLogger.shared.error(.app, "Не вдалося перезапустити програму: \(error?.localizedDescription ?? "невідома помилка")")
                    }
                }
            }
        }
    }

    public func toggleActive() {
        settings.autoSwitchEnabled.toggle()
        settings.save()
        syncEngineState()
        AppLogger.shared.info(.settings, "Автоперемикання змінено на: \(settings.autoSwitchEnabled)")
    }

    public func forceConvert() {
        Task {
            await engine.forceConvertWordOrSelection()
        }
    }

    public func toggleAutostart() {
        let targetState = !isAutostartEnabled
        do {
            if targetState {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshAutostartStatus()
            AppLogger.shared.info(.settings, "Автозапуск змінено на: \(isAutostartEnabled) (status: \(SMAppService.mainApp.status))")
        } catch {
            refreshAutostartStatus()
            showAutostartErrorAlert = true
            AppLogger.shared.error(.settings, "Помилка зміни автозапуску: \(error.localizedDescription)")
        }
    }

    public func applySettings(_ updated: AppSettings) {
        settings = updated
        settings.save()
        i18n.language = updated.uiLanguage
        syncEngineState()
        AppLogger.shared.info(.settings, "Оновлено налаштування: мова=\(updated.uiLanguage.rawValue), хоткей=\(updated.hotkeyPreset.rawValue), автоперемикання=\(updated.autoSwitchEnabled)")
    }

    public func shutdownAndQuit() {
        cleanupObservers()
        Task {
            await engine.stop()
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Приватні обробники

    private func syncEngineState() {
        let preset = settings.hotkeyPreset
        let enabled = settings.autoSwitchEnabled
        let previousTask = settingsSyncTask

        settingsSyncTask = Task {
            _ = await previousTask?.result
            await engine.setHotkeyPreset(preset)
            await engine.setEnabled(enabled)
        }
    }

    private func cleanupObservers() {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
        permissionPollTask?.cancel()
        permissionPollTask = nil
    }

    private func handleSwitchEvent(_ info: SwitchEventInfo) {
        if info.mode == .auto {
            switchCount += 1
        }
        lastSwitchInfo = info
        refreshAccessibilityStatus()
    }

    private func subscribeToWorkspaceNotifications() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            let bundleID = app.bundleIdentifier
            Task { @MainActor in
                guard let self else { return }
                if !self.isAccessibilityTrusted {
                    self.refreshAccessibilityStatus()
                }
                await self.engine.notifyActiveAppChanged(bundleID: bundleID)
            }
        }
    }
}
