import AppKit
import Carbon.HIToolbox
import MochiTestSupport
import XCTest

@testable import MochiApp

/// A hot key service that records what Mochi asks of it and never touches the real keyboard.
@MainActor private final class FakeHotKeys {
    var registered: [UInt32: Shortcut] = [:]
    var refuse: [Shortcut: OSStatus] = [:]
    var reserved: Set<Shortcut> = []
    var deliver: (@MainActor (UInt32, Bool) -> Void)?
    var system: HotKeySystem {
        HotKeySystem(
            register: { [unowned self] shortcut, id in
                if let status = refuse[shortcut] { return status }
                registered[id] = shortcut
                return noErr
            },
            unregisterAll: { [unowned self] in registered = [:] },
            reserved: { [unowned self] in reserved },
            onEvent: { [unowned self] in deliver = $0 })
    }
}

final class ShortcutTests: XCTestCase {
    private let optionCommandM = Shortcut(keyCode: UInt16(kVK_ANSI_M), modifiers: [.option, .command])
    private let controlOptionSpace = Shortcut(keyCode: UInt16(kVK_Space), modifiers: [.control, .option])

    func testAGlobalShortcutNeedsCommandOptionOrControlAndARealKey() {
        XCTAssertNil(optionCommandM.problem)
        XCTAssertNil(Shortcut(keyCode: UInt16(kVK_F5), modifiers: [.control]).problem)
        XCTAssertNotNil(Shortcut(keyCode: UInt16(kVK_ANSI_M), modifiers: []).problem)
        XCTAssertNotNil(Shortcut(keyCode: UInt16(kVK_ANSI_M), modifiers: [.shift]).problem, "Shift alone types")
        XCTAssertNotNil(Shortcut(keyCode: UInt16(kVK_Command), modifiers: [.command]).problem)
    }

    func testShortcutsReadAsMenusShowThem() {
        XCTAssertEqual(controlOptionSpace.display, "⌃⌥Space")
        XCTAssertEqual(
            Shortcut(keyCode: UInt16(kVK_F5), modifiers: [.control, .option, .shift, .command]).display, "⌃⌥⇧⌘F5")
        XCTAssertEqual(Shortcut(keyCode: UInt16(kVK_UpArrow), modifiers: [.command]).display, "⌘↑")
        XCTAssertNil(controlOptionSpace.character)
    }

    func testModifiersConvertBothWaysAndSurviveStorage() throws {
        let all: Shortcut.Modifiers = [.control, .option, .shift, .command]
        XCTAssertEqual(Shortcut.Modifiers(carbon: Int(all.carbon)), all)
        XCTAssertEqual(Shortcut.Modifiers(all.flags), all)
        XCTAssertEqual(Shortcut.Modifiers([.command, .capsLock, .function]), [.command])
        let data = try JSONEncoder().encode(optionCommandM)
        XCTAssertEqual(try JSONDecoder().decode(Shortcut.self, from: data), optionCommandM)
    }

    @MainActor func testRegistersEachBindingAndReportsOnesAnotherAppHolds() {
        let keys = FakeHotKeys()
        let center = ShortcutCenter(system: keys.system, enabled: true)
        var bindings: [ShortcutAction: Shortcut] = [.talk: optionCommandM, .togglePet: controlOptionSpace]
        center.bindings = { bindings }
        keys.refuse[controlOptionSpace] = OSStatus(eventHotKeyExistsErr)
        center.apply()
        XCTAssertEqual(keys.registered, [ShortcutCenter.id(for: .talk): optionCommandM])
        XCTAssertNil(center.problems[.talk])
        XCTAssertEqual(center.problems[.togglePet], "Another app is using this shortcut. Choose a different one.")
        keys.refuse = [:]
        bindings[.togglePet] = nil
        center.apply()
        XCTAssertEqual(keys.registered.count, 1)
        XCTAssertTrue(center.problems.isEmpty, "A removed shortcut leaves no stale problem")
    }

    @MainActor func testRecordingSuspendsEveryShortcutAndRestoresThem() {
        let keys = FakeHotKeys()
        let center = ShortcutCenter(system: keys.system, enabled: true)
        center.bindings = { [.talk: self.optionCommandM] }
        var performed: [(ShortcutAction, Bool)] = []
        center.perform = { performed.append(($0, $1)) }
        center.apply()
        center.recordingAction = .togglePet
        XCTAssertTrue(keys.registered.isEmpty)
        keys.deliver?(ShortcutCenter.id(for: .talk), true)
        XCTAssertTrue(performed.isEmpty, "A key that arrives while recording is the recorder's")
        center.recordingAction = .talk
        XCTAssertTrue(keys.registered.isEmpty, "Moving to the other row keeps everything off")
        center.recordingAction = nil
        XCTAssertEqual(keys.registered.count, 1)
        keys.deliver?(ShortcutCenter.id(for: .talk), true)
        keys.deliver?(ShortcutCenter.id(for: .talk), false)
        keys.deliver?(99, true)
        XCTAssertEqual(performed.map(\.0), [.talk, .talk])
        XCTAssertEqual(performed.map(\.1), [true, false])
    }

    @MainActor func testPreviewsNeverTakeKeys() {
        let keys = FakeHotKeys()
        let center = ShortcutCenter(system: keys.system, enabled: false)
        center.bindings = { [.talk: self.optionCommandM] }
        center.apply()
        XCTAssertTrue(keys.registered.isEmpty)
        XCTAssertNil(keys.deliver)
        XCTAssertFalse(makeApp(demo: true).shortcuts.enabled)
    }

    @MainActor func testConflictsAreNamed() {
        let keys = FakeHotKeys()
        let center = ShortcutCenter(system: keys.system, enabled: true)
        center.bindings = { [.togglePet: self.optionCommandM] }
        let commandN = Shortcut(keyCode: UInt16(kVK_ANSI_N), modifiers: [.command])
        center.menuShortcuts = { [("New Conversation", commandN)] }
        let spotlight = Shortcut(keyCode: UInt16(kVK_Space), modifiers: [.command])
        keys.reserved = [spotlight]
        XCTAssertEqual(
            center.conflict(optionCommandM, for: .talk), "Already used for Show or Hide Desktop Mochi.")
        XCTAssertNil(center.conflict(optionCommandM, for: .togglePet), "Its own shortcut is not a conflict")
        XCTAssertEqual(center.conflict(spotlight, for: .talk), "macOS already uses this shortcut.")
        XCTAssertEqual(
            center.conflict(commandN, for: .talk), "Mochi already uses this shortcut for New Conversation.")
        XCTAssertEqual(
            center.conflict(Shortcut(keyCode: UInt16(kVK_ANSI_N), modifiers: [.shift]), for: .talk),
            "Use Command, Option or Control in the shortcut.")
        XCTAssertNil(center.conflict(controlOptionSpace, for: .talk))
    }

    @MainActor func testMenuKeyEquivalentsBecomeShortcuts() throws {
        _ = NSApplication.shared
        let saved = NSApp.mainMenu
        defer { NSApp.mainMenu = saved }
        let menu = NSMenu()
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        file.submenu = NSMenu(title: "File")
        file.submenu?.addItem(withTitle: "New Conversation", action: nil, keyEquivalent: "n")
        file.submenu?.addItem(withTitle: "From Template", action: nil, keyEquivalent: "N")
        menu.addItem(file)
        NSApp.mainMenu = menu
        let found = ShortcutCenter.mainMenuShortcuts()
        // Key codes come from the current ASCII-capable layout, which always types n somewhere.
        let table = try XCTUnwrap(KeyLayout.current()).table()
        let n = try XCTUnwrap(table.plain["n"])
        XCTAssertEqual(found.map(\.title), ["New Conversation", "From Template"])
        XCTAssertEqual(
            found.map(\.shortcut),
            [
                Shortcut(keyCode: n, modifiers: [.command]), Shortcut(keyCode: n, modifiers: [.command, .shift]),
            ])
    }

    func testMenuKeysNeedingShiftOrWithoutCharactersAreFound() throws {
        let table = try XCTUnwrap(KeyLayout.current()).table()
        let question = try XCTUnwrap(Shortcut.menuKey("?", in: table))
        XCTAssertTrue(question.shift, "? is typed with Shift on an ASCII-capable layout")
        XCTAssertEqual(KeyLayout.current()?.typed(question.keyCode, shift: true), "?")
        let capitalN = try XCTUnwrap(Shortcut.menuKey("N", in: table))
        XCTAssertEqual(capitalN.keyCode, table.plain["n"])
        XCTAssertTrue(capitalN.shift)
        XCTAssertTrue(Shortcut.menuKey("\u{1b}", in: table)! == (UInt16(kVK_Escape), false))
        let up = String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!)
        XCTAssertTrue(Shortcut.menuKey(up, in: table)! == (UInt16(kVK_UpArrow), false))
        let f5 = String(UnicodeScalar(UInt32(NSF1FunctionKey + 4))!)
        XCTAssertTrue(Shortcut.menuKey(f5, in: table)! == (UInt16(kVK_F5), false))
    }

    @MainActor func testASavedShortcutThatNowClashesIsNotRegistered() {
        let keys = FakeHotKeys()
        let center = ShortcutCenter(system: keys.system, enabled: true)
        center.bindings = { [.talk: self.optionCommandM, .togglePet: self.controlOptionSpace] }
        center.menuShortcuts = { [("Minimize All", self.optionCommandM)] }
        center.apply()
        XCTAssertEqual(keys.registered, [ShortcutCenter.id(for: .togglePet): controlOptionSpace])
        XCTAssertEqual(center.problems[.talk], "Mochi already uses this shortcut for Minimize All.")
    }

    @MainActor func testShortcutsStartAtTheirDefaultsAndRemovalsStick() {
        let defaults = makePreferences()
        let talk = Shortcut(keyCode: UInt16(kVK_ANSI_M), modifiers: [.control, .option, .command])
        let pet = Shortcut(keyCode: UInt16(kVK_ANSI_H), modifiers: [.control, .option, .command])
        let first = PreferencesStore(defaults, importLegacy: false, allowExternalControl: false)
        XCTAssertEqual(first.shortcuts, [.talk: talk, .togglePet: pet])
        XCTAssertEqual(first.shortcuts, ShortcutAction.defaults)
        first.shortcuts[.talk] = optionCommandM
        first.shortcuts[.togglePet] = nil
        let second = PreferencesStore(defaults, importLegacy: false, allowExternalControl: false)
        XCTAssertEqual(second.shortcuts, [.talk: optionCommandM], "A removed shortcut does not come back")
        second.shortcuts = ShortcutAction.defaults
        XCTAssertNil(defaults.object(forKey: ShortcutAction.talk.preferenceKey), "Defaults are not stored")
        XCTAssertNil(defaults.object(forKey: ShortcutAction.togglePet.preferenceKey))
        XCTAssertEqual(
            PreferencesStore(defaults, importLegacy: false, allowExternalControl: false).shortcuts,
            ShortcutAction.defaults)
    }

    @MainActor func testThePetPersistsAndBadValuesFallBack() {
        let defaults = makePreferences()
        let first = PreferencesStore(defaults, importLegacy: false, allowExternalControl: false)
        XCTAssertFalse(first.petVisible)
        XCTAssertNil(first.petOrigin)
        first.petVisible = true
        first.petOrigin = CGPoint(x: 12, y: 34)
        let second = PreferencesStore(defaults, importLegacy: false, allowExternalControl: false)
        XCTAssertTrue(second.petVisible)
        XCTAssertEqual(second.petOrigin, CGPoint(x: 12, y: 34))
        second.petOrigin = nil
        XCTAssertNil(defaults.object(forKey: "desktopPetOrigin"))
        defaults.set(Data("not json".utf8), forKey: ShortcutAction.talk.preferenceKey)
        defaults.set(
            try? JSONEncoder().encode(Shortcut(keyCode: UInt16(kVK_ANSI_M), modifiers: [])),
            forKey: ShortcutAction.togglePet.preferenceKey)
        defaults.set([1.0], forKey: "desktopPetOrigin")
        let repaired = PreferencesStore(defaults, importLegacy: false, allowExternalControl: false)
        XCTAssertEqual(
            repaired.shortcuts, ShortcutAction.defaults, "Unreadable or modifier-less shortcuts fall back to defaults")
        XCTAssertNil(repaired.petOrigin)
    }

    func testDefaultShortcutsAreUsableAndDistinct() {
        for action in ShortcutAction.allCases { XCTAssertNil(action.defaultShortcut.problem, "\(action)") }
        XCTAssertEqual(Set(ShortcutAction.defaults.values).count, ShortcutAction.allCases.count)
        XCTAssertEqual(ShortcutAction.talk.defaultShortcut.display, "⌃⌥⌘M")
        XCTAssertEqual(ShortcutAction.togglePet.defaultShortcut.display, "⌃⌥⌘H")
    }

    /// The real service, with a combination nothing else uses, released before the test ends.
    @MainActor func testCarbonRegistersRefusesADuplicateAndReadsReservedShortcuts() {
        let hotKeys = CarbonHotKeys.shared
        defer { hotKeys.unregisterAll() }
        let rare = Shortcut(keyCode: UInt16(kVK_F19), modifiers: [.control, .option, .shift, .command])
        XCTAssertEqual(hotKeys.register(rare, id: 900), noErr)
        XCTAssertEqual(hotKeys.register(rare, id: 901), OSStatus(eventHotKeyExistsErr))
        hotKeys.unregisterAll()
        XCTAssertEqual(hotKeys.register(rare, id: 902), noErr, "Unregistering frees the keys")
        XCTAssertFalse(CarbonHotKeys.reserved().contains(rare))
        // Every Mac turns on some system shortcuts, such as the ones that switch Spaces or input sources.
        XCTAssertFalse(CarbonHotKeys.reserved().isEmpty)
    }

    @MainActor func testSettingAShortcutStoresAndRegistersIt() {
        let app = makeApp(demo: true)
        app.setShortcut(optionCommandM, for: .talk)
        XCTAssertEqual(app.settings.shortcuts[.talk], optionCommandM)
        app.setShortcut(nil, for: .talk)
        XCTAssertNil(app.settings.shortcuts[.talk])
        XCTAssertEqual(app.settings.shortcuts[.togglePet], ShortcutAction.togglePet.defaultShortcut)
    }
}
