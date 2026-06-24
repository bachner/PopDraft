// PopDraft - Popup Menu App
// A menu bar app that shows a floating action popup for text processing
//
// Built by co-compiling with scripts/Core.swift:
//   swiftc -O scripts/PopDraft.swift scripts/Core.swift \
//       -framework Cocoa -framework Carbon -framework WebKit -framework AVFoundation

import Cocoa
import SwiftUI
import Carbon.HIToolbox
import WebKit
import CryptoKit
import Network

// MARK: - Hotkey Manager

class HotkeyManager {
    static let shared = HotkeyManager()

    struct HotkeyConfig {
        let id: UInt32
        let keyCode: UInt32
        let modifiers: UInt32
        let actionID: String
        let description: String
    }

    // Key code mapping
    private let keyCodeMap: [String: UInt32] = [
        "A": 0, "B": 11, "C": 8, "D": 2, "E": 14, "F": 3, "G": 5, "H": 4,
        "I": 34, "J": 38, "K": 40, "L": 37, "M": 46, "N": 45, "O": 31, "P": 35,
        "Q": 12, "R": 15, "S": 1, "T": 17, "U": 32, "V": 9, "W": 13, "X": 7,
        "Y": 16, "Z": 6, "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
        "6": 22, "7": 26, "8": 28, "9": 25, "SPACE": 49, "`": 50, "~": 50
    ]

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var registeredHotkeys: [HotkeyConfig] = []

    func buildHotkeys() -> [HotkeyConfig] {
        let config = LLMConfig.load()
        var hotkeys: [HotkeyConfig] = []
        var id: UInt32 = 1

        // Register popup hotkey (Option + configured key)
        let popupKey = config.popupHotkey.uppercased()
        if let popupKeyCode = keyCodeMap[popupKey] {
            hotkeys.append(HotkeyConfig(id: id, keyCode: popupKeyCode, modifiers: UInt32(optionKey), actionID: "popup", description: "Option+\(popupKey)"))
            id += 1
        }

        // Register shortcuts for all enabled actions
        for action in ActionManager.shared.actions where action.isEnabled {
            guard let shortcutKey = action.shortcut,
                  let keyCode = keyCodeMap[shortcutKey.uppercased()] else { continue }

            hotkeys.append(HotkeyConfig(
                id: id,
                keyCode: keyCode,
                modifiers: UInt32(controlKey | optionKey),
                actionID: action.id,
                description: "Ctrl+Option+\(shortcutKey)"
            ))
            id += 1
        }

        // Register custom prompt shortcut
        if ActionManager.shared.customPromptEnabled,
           let cpShortcut = ActionManager.shared.customPromptShortcut,
           let keyCode = keyCodeMap[cpShortcut.uppercased()] {
            hotkeys.append(HotkeyConfig(
                id: id,
                keyCode: keyCode,
                modifiers: UInt32(controlKey | optionKey),
                actionID: "custom_prompt",
                description: "Ctrl+Option+\(cpShortcut)"
            ))
            id += 1
        }

        return hotkeys
    }

    func registerAll() {
        registeredHotkeys = buildHotkeys()

        // Install single event handler for all hotkeys
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { (_, event, _) -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)

            DispatchQueue.main.async {
                HotkeyManager.shared.handleHotkey(id: hotKeyID.id)
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, &eventHandlerRef)

        // Register each hotkey
        for config in registeredHotkeys {
            let hotKeyID = EventHotKeyID(signature: OSType(0x504450), id: config.id) // "PDP" signature
            var hotKeyRef: EventHotKeyRef?

            let status = RegisterEventHotKey(config.keyCode, config.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

            if status == noErr, let ref = hotKeyRef {
                hotKeyRefs[config.id] = ref
                print("Registered hotkey: \(config.description) -> \(config.actionID)")
            } else {
                print("Failed to register hotkey: \(config.description) (status: \(status))")
            }
        }
    }

    func unregisterAll() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()

        if let handlerRef = eventHandlerRef {
            RemoveEventHandler(handlerRef)
            eventHandlerRef = nil
        }
    }

    func reloadHotkeys() {
        unregisterAll()
        registerAll()
    }

    func handleHotkey(id: UInt32) {
        guard let config = registeredHotkeys.first(where: { $0.id == id }) else {
            Logger.shared.error("handleHotkey: no registered hotkey for id \(id)")
            return
        }
        Logger.shared.info("handleHotkey fired: id=\(id) action=\(config.actionID) (\(config.description))")

        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.triggerAction(actionID: config.actionID)
        } else {
            Logger.shared.error("handleHotkey: NSApp.delegate is not AppDelegate — cannot trigger action")
        }
    }
}
