//
//  settings.swift
//  Pablo Switcher
//
//  Created by Serhii Meleshchuk on 23.11.2026.
//

import AppKit
import SwiftUI

public struct SettingsView: View {
    public let store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var draftLanguage: LangCode
    @State private var draftHotkey: HotkeyPreset
    @State private var draftAutoSwitch: Bool

    public init(store: AppStore) {
        self.store = store
        _draftLanguage = State(initialValue: store.settings.uiLanguage)
        _draftHotkey = State(initialValue: store.settings.hotkeyPreset)
        _draftAutoSwitch = State(initialValue: store.settings.autoSwitchEnabled)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Picker(store.i18n.t("settings_ui_lang"), selection: $draftLanguage) {
                    Text("Українська (UA)").tag(LangCode.uk)
                    Text("English (EN)").tag(LangCode.en)
                }

                Picker(store.i18n.t("settings_hotkey"), selection: $draftHotkey) {
                    ForEach(HotkeyPreset.allCases, id: \.self) { preset in
                        Text(store.i18n.hotkeyLabel(for: preset)).tag(preset)
                    }
                }

                Toggle(store.i18n.t("settings_autoswitch_checkbox"), isOn: $draftAutoSwitch)
                    .padding(.top, 4)
            }
            .formStyle(.grouped)

            Text(store.i18n.t("settings_hint"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)

            HStack(spacing: 10) {
                Spacer()

                Button(store.i18n.t("settings_cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(store.i18n.t("settings_save")) {
                    var updated = store.settings
                    updated.uiLanguage = draftLanguage
                    updated.hotkeyPreset = draftHotkey
                    updated.autoSwitchEnabled = draftAutoSwitch
                    store.applySettings(updated)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding([.horizontal, .bottom], 20)
            .padding(.top, 4)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            activateApp()
            syncDrafts(from: store.settings)
        }
        .onChange(of: store.settings) { _, newSettings in
            syncDrafts(from: newSettings)
        }
    }

    private func syncDrafts(from settings: AppSettings) {
        draftLanguage = settings.uiLanguage
        draftHotkey = settings.hotkeyPreset
        draftAutoSwitch = settings.autoSwitchEnabled
    }

    private func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@MainActor
public enum AboutDialogPresenter {
    private static var isPresenting = false

    public static func show(i18n: XMLI18nManager) {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        guard !isPresenting else { return }
        isPresenting = true
        defer { isPresenting = false }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.1"

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSImage(named: NSImage.applicationIconName)
        alert.messageText = i18n.t("about_title")
        alert.informativeText = i18n.t("about_body", args: ["version": version])
        alert.window.level = .floating
        alert.runModal()
    }
}
