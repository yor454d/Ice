//
//  HotkeyRecorder.swift
//  Ice
//

import Combine
import SwiftUI

/// Model for a hotkey recorder's state.
private class HotkeyRecorderModel: ObservableObject {
    /// An alias for a type that describes a recording failure.
    typealias Failure = HotkeyRecorder.Failure

    /// Retained observers to help manage the state of the model.
    private var cancellables = Set<AnyCancellable>()

    /// The section managed by the model.
    let section: StatusBarSection?

    /// A Boolean value that indicates whether the hotkey recorder
    /// is currently recording.
    @Published private(set) var isRecording = false

    /// Strings representing the currently pressed modifiers when the
    /// hotkey recorder is recording. Empty if the hotkey recorder is
    /// not recording.
    @Published private(set) var pressedModifierStrings = [String]()

    /// A closure that handles recording failures.
    private let handleFailure: (HotkeyRecorderModel, Failure) -> Void

    /// A closure that removes the failure associated with the
    /// hotkey recorder.
    private let removeFailure: () -> Void

    /// Local event monitor that listens for key down events and
    /// modifier flag changes.
    private var monitor: LocalEventMonitor?

    /// A Boolean value that indicates whether the hotkey is
    /// currently enabled.
    var isEnabled: Bool { section?.hotkeyIsEnabled ?? false }

    /// Creates a model for a hotkey recorder that records user-chosen
    /// key combinations for the given section's hotkey.
    init(
        section: StatusBarSection?,
        onFailure: @escaping (Failure) -> Void,
        removeFailure: @escaping () -> Void
    ) {
        defer {
            configureCancellables()
        }
        self.section = section
        self.handleFailure = { model, failure in
            // immediately remove the modifier strings, before the failure
            // handler is even performed; it looks weird to have the pressed
            // modifiers displayed in the hotkey recorder at the same time
            // as a failure
            model.pressedModifierStrings.removeAll()
            onFailure(failure)
        }
        self.removeFailure = removeFailure
        guard !ProcessInfo.processInfo.isPreview else {
            return
        }
        self.monitor = LocalEventMonitor(mask: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else {
                return event
            }
            switch event.type {
            case .keyDown:
                handleKeyDown(event: event)
            case .flagsChanged:
                handleFlagsChanged(event: event)
            default:
                return event
            }
            return nil
        }
    }

    deinit {
        stopRecording()
    }

    /// Sets up a series of observers to respond to important changes
    /// in the model's state.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()
        if let section {
            c.insert(section.$hotkey.sink { [weak self] _ in
                self?.objectWillChange.send()
            })
        }
        cancellables = c
    }

    /// Disables the hotkey and starts monitoring for events.
    func startRecording() {
        guard !isRecording else {
            return
        }
        isRecording = true
        section?.disableHotkey()
        monitor?.start()
        pressedModifierStrings = []
    }

    /// Enables the hotkey and stops monitoring for events.
    func stopRecording() {
        guard isRecording else {
            return
        }
        isRecording = false
        monitor?.stop()
        section?.enableHotkey()
        pressedModifierStrings = []
        removeFailure()
    }

    /// Handles local key down events when the hotkey recorder is recording.
    private func handleKeyDown(event: NSEvent) {
        let hotkey = Hotkey(event: event)
        if hotkey.modifiers.isEmpty {
            if hotkey.key == .escape {
                // cancel when escape is pressed with no modifiers
                stopRecording()
            } else {
                handleFailure(self, .noModifiers)
            }
            return
        }
        if hotkey.modifiers == .shift {
            handleFailure(self, .onlyShift)
            return
        }
        if hotkey.isReservedBySystem {
            handleFailure(self, .reserved(hotkey))
            return
        }
        // if we made it this far, all checks passed; assign the
        // new hotkey and stop recording
        section?.hotkey = hotkey
        stopRecording()
    }

    /// Handles modifier flag changes when the hotkey recorder is recording.
    private func handleFlagsChanged(event: NSEvent) {
        pressedModifierStrings = Hotkey.Modifiers.canonicalOrder.compactMap {
            event.modifierFlags.contains($0.nsEventFlags) ? $0.stringValue : nil
        }
    }
}

/// A view that records user-chosen key combinations for a hotkey.
struct HotkeyRecorder: View {
    /// An error type that describes a recording failure.
    enum Failure: LocalizedError, Hashable {
        /// No modifiers were pressed.
        case noModifiers
        /// Shift was the only modifier being pressed.
        case onlyShift
        /// The given hotkey is reserved by macOS.
        case reserved(Hotkey)

        var errorDescription: String? {
            switch self {
            case .noModifiers:
                return "Hotkey should include at least one modifier"
            case .onlyShift:
                return "Shift (⇧) cannot be a hotkey's only modifier"
            case .reserved(let hotkey):
                return "Hotkey \(hotkey.stringValue) is reserved by macOS"
            }
        }
    }

    /// The model that manages the hotkey recorder.
    @StateObject private var model: HotkeyRecorderModel

    /// The hotkey recorder's frame.
    @State private var frame: CGRect = .zero

    /// A Boolean value that indicates whether the mouse is currently
    /// inside the bounds of the recorder's second segment.
    @State private var isInsideSegment2 = false

    /// A binding that holds information about the current recording
    /// failure on behalf of the recorder.
    @Binding var failure: Failure?

    /// Creates a hotkey recorder that records user-chosen key
    /// combinations for the given section.
    ///
    /// - Parameters:
    ///   - section: The section that the recorder records hotkeys for.
    ///   - failure: A binding to a property that holds information about
    ///     the current recording failure on behalf of the recorder.
    init(section: StatusBarSection?, failure: Binding<Failure?>) {
        let model = HotkeyRecorderModel(section: section) {
            failure.wrappedValue = $0
        } removeFailure: {
            failure.wrappedValue = nil
        }
        self._model = StateObject(wrappedValue: model)
        self._failure = failure
    }

    var body: some View {
        HStack(spacing: 1) {
            segment1
            segment2
        }
        .foregroundColor(.primary)
        .frame(width: 160, height: 24)
        .onFrameChange(update: $frame)
        .error(failure)
    }

    @ViewBuilder
    private var segment1: some View {
        Button {
            model.startRecording()
        } label: {
            Color.clear
                .overlay(
                    segment1Label
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity
                        )
                )
        }
        .help(segment1HelpString)
        .configureSettingsButtons {
            $0.shape = .leadingSegment
            $0.isHighlighted = model.isRecording
        }
    }

    @ViewBuilder
    private var segment2: some View {
        Button {
            if model.isRecording {
                model.stopRecording()
            } else if model.isEnabled {
                model.section?.hotkey = nil
            } else {
                model.startRecording()
            }
        } label: {
            Color.clear
                .overlay(
                    segment2Label
                )
        }
        .frame(width: frame.height)
        .onHover { isInside in
            isInsideSegment2 = isInside
        }
        .help(segment2HelpString)
        .configureSettingsButtons {
            $0.shape = .trailingSegment
        }
    }

    @ViewBuilder
    private var segment1Label: some View {
        if model.isRecording {
            if isInsideSegment2 {
                Text("Cancel")
            } else if !model.pressedModifierStrings.isEmpty {
                HStack(spacing: 1) {
                    ForEach(model.pressedModifierStrings, id: \.self) { string in
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.background.opacity(0.5))
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(Text(string))
                    }
                }
            } else {
                Text("Type Hotkey")
            }
        } else if model.isEnabled {
            HStack {
                Text(modifierString)
                Text(keyString)
            }
        } else {
            Text("Record Hotkey")
        }
    }

    @ViewBuilder
    private var segment2Label: some View {
        Image(systemName: symbolString)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .padding(3)
    }

    private var modifierString: String {
        model.section?.hotkey?.modifiers.stringValue ?? ""
    }

    private var keyString: String {
        guard let key = model.section?.hotkey?.key else {
            return ""
        }
        return key.stringValue.capitalized
    }

    private var symbolString: String {
        if model.isRecording {
            return "escape"
        }
        if model.isEnabled {
            return "xmark.circle.fill"
        }
        return "record.circle"
    }

    private var segment1HelpString: String {
        if model.isRecording {
            return ""
        }
        if model.isEnabled {
            return "Click to record new hotkey"
        }
        return "Click to record hotkey"
    }

    private var segment2HelpString: String {
        if model.isRecording {
            return "Cancel recording"
        }
        if model.isEnabled {
            return "Delete hotkey"
        }
        return "Click to record hotkey"
    }
}

struct HotkeyRecorder_Previews: PreviewProvider {
    static var previews: some View {
        HotkeyRecorder(section: nil, failure: .constant(nil))
            .padding()
            .buttonStyle(SettingsButtonStyle())
    }
}
