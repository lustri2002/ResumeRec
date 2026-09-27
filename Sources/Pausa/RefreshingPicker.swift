import AppKit
import SwiftUI

struct PickerOption<Value: Hashable>: Equatable {
    let value: Value
    let title: String
}

/// Fetches before opening: AppKit does not reflect menu mutations while tracking.
struct RefreshingPicker<Value: Hashable>: NSViewRepresentable {
    let label: String
    @Binding var selection: Value
    let options: [PickerOption<Value>]
    let placeholder: String
    let loadOptions: @MainActor () async throws -> [PickerOption<Value>]
    let onError: @MainActor (Error) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> RefreshingPopUpButton {
        let button = RefreshingPopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = false
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selected(_:))
        button.onOpen = { [weak coordinator = context.coordinator, weak button] in
            guard let button else { return }
            coordinator?.open(button)
        }
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: RefreshingPopUpButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(label)
        guard !button.isLoading, !button.isPresenting else { return }
        context.coordinator.populate(button, with: options)
    }

    static func dismantleNSView(_ button: RefreshingPopUpButton, coordinator: Coordinator) {
        coordinator.task?.cancel()
        button.onOpen = nil
    }

    @MainActor final class Coordinator: NSObject {
        var parent: RefreshingPicker
        var task: Task<Void, Never>?
        private var displayedOptions: [PickerOption<Value>] = []

        init(_ parent: RefreshingPicker) { self.parent = parent }

        func populate(_ button: RefreshingPopUpButton, with options: [PickerOption<Value>]) {
            displayedOptions = options
            let menu = NSMenu()
            menu.autoenablesItems = false
            for (index, option) in options.enumerated() {
                let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
                item.tag = index
                menu.addItem(item)
            }
            let selection = options.firstIndex { $0.value == parent.selection }
            if selection == nil {
                let item = NSMenuItem(title: parent.placeholder, action: nil, keyEquivalent: "")
                item.tag = -1; item.isEnabled = false
                menu.insertItem(item, at: 0)
            }
            button.menu = menu
            button.selectItem(withTag: selection ?? -1)
        }

        func open(_ button: RefreshingPopUpButton) {
            guard task == nil, button.isEnabled else { return }
            button.isLoading = true
            button.selectedItem?.title = "Refreshing…"
            task = Task { [weak self, weak button] in
                guard let self, let button else { return }
                defer { button.isLoading = false; self.task = nil }
                do {
                    let options = try await self.parent.loadOptions()
                    try Task.checkCancellation()
                    self.populate(button, with: options)
                    button.isLoading = false
                    guard button.window?.isVisible == true, button.isEnabled else { return }
                    button.presentUpdatedMenu()
                } catch is CancellationError {
                    // The control disappeared (for example, another tab was selected).
                } catch {
                    self.populate(button, with: self.parent.options)
                    self.parent.onError(error)
                }
            }
        }

        @objc func selected(_ button: NSPopUpButton) {
            let index = button.selectedTag()
            guard displayedOptions.indices.contains(index) else { return }
            parent.selection = displayedOptions[index].value
        }
    }
}

final class RefreshingPopUpButton: NSPopUpButton {
    var onOpen: (() -> Void)?
    var isLoading = false
    var isPresenting = false

    override func mouseDown(with event: NSEvent) { performClick(nil) }
    override func performClick(_ sender: Any?) {
        guard isEnabled, !isLoading, !isPresenting else { return }
        window?.makeFirstResponder(self)
        onOpen?()
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }
    override func keyDown(with event: NSEvent) {
        if [UInt16(36), 49, 76, 125, 126].contains(event.keyCode) { performClick(nil) }
        else { super.keyDown(with: event) }
    }
    func presentUpdatedMenu() {
        isPresenting = true
        defer { isPresenting = false }
        super.performClick(nil)
    }
}
