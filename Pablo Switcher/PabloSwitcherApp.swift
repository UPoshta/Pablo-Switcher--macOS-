import SwiftUI

@main
struct AutoSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @State private var store: AppStore
    @Environment(\.openWindow) private var openWindow

    private let menuBarIcon: NSImage

    init() {
        let provider = BundledWordFrequencyProvider()
        let appStore = AppStore(frequencyProvider: provider)
        _store = State(initialValue: appStore)
        self.menuBarIcon = MenuBarIconRenderer.makeMenuBarImage()
        appDelegate.store = appStore
    }

    var body: some Scene {
        // 1. Іконка та меню в Menu Bar
        MenuBarExtra {
            Button(store.statusTitle) {
                store.openAccessibilitySettings()
            }
            .disabled(store.isAccessibilityTrusted)

            Text(store.lastActionTitle)
            Text(store.statsTitle)

            Divider()

            Button(store.toggleTitle) {
                store.toggleActive()
            }

            Button(store.forceConvertTitle) {
                store.forceConvert()
            }

            Toggle(store.i18n.t("menu_autostart"), isOn: Binding(
                get: { store.isAutostartEnabled },
                set: { _ in store.toggleAutostart() }
            ))

            Divider()

            Button(store.i18n.t("menu_settings")) {
                store.refreshAutostartStatus()
                openWindow(id: "settings")
                activateApp()
            }

            Button(store.i18n.t("menu_open_logs")) {
                openLogFile()
            }

            Button(store.i18n.t("menu_about")) {
                activateApp()
                AboutDialogPresenter.show(i18n: store.i18n)
            }

            Divider()

            Button(store.i18n.t("menu_quit")) {
                store.shutdownAndQuit()
            }
        } label: {
            Image(nsImage: menuBarIcon)
        }

        // 2. Вікно налаштувань
        Window(store.i18n.t("menu_settings"), id: "settings") {
            SettingsView(store: store)
                .onAppear {
                    store.refreshAutostartStatus()
                }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    private func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func openLogFile() {
        let logURL = AppLogger.shared.currentLogURL
        let path = logURL.path(percentEncoded: false)

        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(logURL)
        } else {
            // Якщо файл ще не створено, відкриваємо батьківську теку Logs
            NSWorkspace.shared.open(logURL.deletingLastPathComponent())
        }
    }
}

@MainActor
private final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?

    func applicationWillTerminate(_ notification: Notification) {
        // Гарантуємо зупинку CGEventTap навіть при зовнішньому завершенні процесу (Cmd+Q, перезавантаження macOS)
        store?.shutdownAndQuit()
    }
}
