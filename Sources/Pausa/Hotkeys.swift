import Carbon
import PausaCore

final class Hotkeys {
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    var action: ((UInt32) -> Void)?
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            let object = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            object.action?(identifier.id)
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func configure(_ preferences: Preferences) -> String {
        references.forEach { UnregisterEventHotKey($0) }; references = []
        guard preferences.hotkeysEnabled else { return "" }
        let letters = [preferences.startKey, preferences.pauseKey, preferences.stopKey]
        guard Set(letters).count == 3 else { return "Choose three different letters. Shortcuts are currently disabled." }
        // Physical ANSI positions; labels follow Latin/QWERTY layouts.
        let codes: [String: UInt32] = ["A":0,"S":1,"D":2,"F":3,"H":4,"G":5,"Z":6,"X":7,"C":8,"V":9,"B":11,
                                      "Q":12,"W":13,"E":14,"R":15,"Y":16,"T":17,"O":31,"U":32,"I":34,"P":35,
                                      "L":37,"J":38,"K":40,"N":45,"M":46]
        for (index, letter) in letters.enumerated() {
            guard let code = codes[letter] else { continue }
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(code, UInt32(controlKey | optionKey | cmdKey),
                                             EventHotKeyID(signature: 0x50415553, id: UInt32(index)),
                                             GetApplicationEventTarget(), 0, &reference)
            if status != noErr {
                references.forEach { UnregisterEventHotKey($0) }; references = []
                return "Shortcut \(letter) is unavailable. Choose a different letter."
            }
            if let reference { references.append(reference) }
        }
        return ""
    }
    deinit { references.forEach { UnregisterEventHotKey($0) }; if let handler { RemoveEventHandler(handler) } }
}
