import AppKit

// MARK: - Warning panel

/// A floating panel used for the 15 / 5 / 1 minute and 30 second warnings.
final class WarningPanel: NSObject {

    private var window: NSWindow?
    private var autoCloseTimer: Timer?
    private var extendHandler: (() -> Void)?

    func show(headline: String, detail: String, allowExtend: Bool, extendHandler: (() -> Void)?) {
        close()
        self.extendHandler = extendHandler

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 170),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        icon.contentTintColor = .systemRed
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(wrappingLabelWithString: headline)
        title.font = NSFont.systemFont(ofSize: 19, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(wrappingLabelWithString: detail)
        subtitle.font = NSFont.systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let dismiss = NSButton(title: "OK", target: self, action: #selector(dismissPressed))
        dismiss.bezelStyle = .rounded
        dismiss.keyEquivalent = "\r"

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        if allowExtend {
            let extend = NSButton(title: "Add 15 minutes", target: self, action: #selector(extendPressed))
            extend.bezelStyle = .rounded
            buttons.addArrangedSubview(extend)
        }
        buttons.addArrangedSubview(dismiss)

        let content = NSView()
        content.addSubview(icon)
        content.addSubview(title)
        content.addSubview(subtitle)
        content.addSubview(buttons)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),

            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: subtitle.bottomAnchor, constant: 16),
        ])

        window.contentView = content
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        // The final 30 second warning stays up until the Mac goes down.
        if allowExtend || headline.contains("minute") {
            let timer = Timer(timeInterval: 45, repeats: false) { [weak self] _ in self?.close() }
            RunLoop.main.add(timer, forMode: .common)
            autoCloseTimer = timer
        }
    }

    @objc private func extendPressed() {
        let handler = extendHandler
        close()
        handler?()
    }

    @objc private func dismissPressed() { close() }

    func close() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
        window?.orderOut(nil)
        window = nil
        extendHandler = nil
    }
}

// MARK: - Settings window

final class SettingsWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow!
    private let picker = NSDatePicker()
    private let lockPicker = NSDatePicker()
    private let enabledBox = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let loginBox = NSButton(checkboxWithTitle: "Start at login", target: nil, action: nil)
    private let lockButton = NSButton(title: "Lock", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let lockState = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let onSave: () -> Void

    private let contentWidth: CGFloat = 460

    init(onSave: @escaping () -> Void) {
        self.onSave = onSave
        super.init()
        build()
    }

    // MARK: Layout

    private func build() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "AutoShutdown"
        window.isReleasedWhenClosed = false
        window.delegate = self

        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.hourMinute]

        lockPicker.datePickerStyle = .textFieldAndStepper
        lockPicker.datePickerElements = [.yearMonthDay, .hourMinute]

        lockButton.bezelStyle = .rounded
        lockButton.target = self
        lockButton.action = #selector(lockPressed)

        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(savePressed)
        saveButton.keyEquivalent = "\r"

        lockState.font = NSFont.systemFont(ofSize: 11)
        lockState.textColor = .secondaryLabelColor

        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(sectionTitle("Daily shutdown"))
        stack.addArrangedSubview(row([label("Shut down every day at"), picker]))
        stack.addArrangedSubview(enabledBox)
        stack.addArrangedSubview(loginBox)
        stack.addArrangedSubview(fullWidth(caption(
            "An earlier time applies today. A later time only takes effect tomorrow, so the time left today can never grow. One +15 minute extension is allowed per day."), in: stack))

        stack.addArrangedSubview(fullWidth(separator(), in: stack))

        stack.addArrangedSubview(sectionTitle("Commitment lock"))
        stack.addArrangedSubview(fullWidth(caption(
            "Pick a date and time to lock these settings until. While the lock holds you can still make things stricter, an earlier shutdown or a longer lock, but nothing that buys you time. The app also stays switched on."), in: stack))
        stack.addArrangedSubview(row([label("Lock settings until"), lockPicker, lockButton]))
        stack.addArrangedSubview(fullWidth(lockState, in: stack))

        stack.addArrangedSubview(fullWidth(separator(), in: stack))
        stack.addArrangedSubview(fullWidth(status, in: stack))

        let bottomRow = NSView()
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        bottomRow.addSubview(saveButton)
        NSLayoutConstraint.activate([
            saveButton.trailingAnchor.constraint(equalTo: bottomRow.trailingAnchor),
            saveButton.topAnchor.constraint(equalTo: bottomRow.topAnchor),
            saveButton.bottomAnchor.constraint(equalTo: bottomRow.bottomAnchor),
        ])
        stack.addArrangedSubview(fullWidth(bottomRow, in: stack))

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
        ])

        window.contentView = content
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: contentWidth, height: stack.fittingSize.height + 44))
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: 13)
        return field
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        return field
    }

    private func caption(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = NSFont.systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func fullWidth(_ view: NSView, in stack: NSStackView) -> NSView {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return view
    }

    // MARK: State

    func show() {
        refresh()
        status.stringValue = ""
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func refresh() {
        var comps = DateComponents()
        comps.year = 2000
        comps.month = 1
        comps.day = 1
        comps.hour = Prefs.shared.hour
        comps.minute = Prefs.shared.minute
        picker.dateValue = Calendar.current.date(from: comps) ?? Date()

        enabledBox.state = Prefs.shared.enabled ? .on : .off
        enabledBox.target = self
        enabledBox.action = #selector(enabledToggled)

        let locked = Prefs.shared.isLocked
        enabledBox.isEnabled = !(locked && Prefs.shared.enabled)

        loginBox.target = self
        loginBox.action = #selector(loginToggled)
        let registered = LoginItem.isEnabled
        loginBox.state = registered ? .on : .off
        // A lock must not be escapable by simply not starting the app tomorrow.
        loginBox.isEnabled = !(locked && registered) && LoginItem.conflictingAgent == nil
        if let stale = LoginItem.conflictingAgent {
            loginBox.toolTip = "Handled by an older login item at \(stale.path)"
        } else {
            loginBox.toolTip = nil
        }

        lockPicker.minDate = Date()
        if let until = Prefs.shared.lockUntil {
            lockState.stringValue = "Locked until \(lockStamp(until)). The shutdown time can only be moved earlier."
            if lockPicker.dateValue < until { lockPicker.dateValue = until }
            lockButton.title = "Extend lock"
        } else {
            lockState.stringValue = "No lock. Settings can be changed freely."
            if lockPicker.dateValue <= Date() {
                lockPicker.dateValue = Date().addingTimeInterval(86_400)
            }
            lockButton.title = "Lock"
        }
    }

    // MARK: Actions

    @objc private func enabledToggled() {
        // The checkbox is only a staging value; Save commits it.
    }

    /// Unlike the other controls this one takes effect at once, because it is a
    /// registration with macOS rather than a stored preference.
    @objc private func loginToggled() {
        let wanted = loginBox.state == .on

        if Prefs.shared.isLocked && !wanted {
            status.stringValue = "Locked. Starting at login cannot be switched off until the lock expires."
            refresh()
            return
        }

        if LoginItem.setEnabled(wanted) {
            status.stringValue = wanted
                ? "AutoShutdown will start at every login."
                : "AutoShutdown will no longer start at login."
        } else {
            status.stringValue = "macOS refused the change. Check System Settings > General > Login Items."
        }
        refresh()
    }

    @objc private func savePressed() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: picker.dateValue)
        let newHour = comps.hour ?? 23
        let newMinute = comps.minute ?? 0
        let locked = Prefs.shared.isLocked

        if locked {
            let current = nextOccurrence(hour: Prefs.shared.hour, minute: Prefs.shared.minute)
            let proposed = nextOccurrence(hour: newHour, minute: newMinute)
            if proposed > current {
                let until = Prefs.shared.lockUntil.map(lockStamp) ?? ""
                status.stringValue = "Locked until \(until). The shutdown time can only be moved earlier."
                refresh()
                return
            }
        }

        let previousDeadline = todayTarget()
        Prefs.shared.hour = newHour
        Prefs.shared.minute = newMinute
        if !locked { Prefs.shared.enabled = enabledBox.state == .on }

        let newDeadline = baseTarget(on: Date())
        if newDeadline > previousDeadline && previousDeadline > Date() {
            // Never hand back time: today keeps the earlier deadline.
            Prefs.shared.overrideToday = previousDeadline
            status.stringValue = "Today still shuts down at \(clock(previousDeadline)). The new time starts tomorrow."
        } else {
            Prefs.shared.overrideToday = nil
            status.stringValue = "Saved. Applies from today."
        }

        Prefs.shared.flush()
        onSave()
        refresh()
    }

    @objc private func lockPressed() {
        let proposed = lockPicker.dateValue

        guard proposed > Date() else {
            status.stringValue = "Pick a moment in the future."
            return
        }

        if let current = Prefs.shared.lockUntil, proposed <= current {
            status.stringValue = "The lock already runs to \(lockStamp(current)). It can only be pushed further out."
            refresh()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Lock settings until \(lockStamp(proposed))?"
        alert.informativeText = "Until then the shutdown time can only be moved earlier, the lock can only be extended, and the app cannot be switched off. This cannot be undone from inside the app."
        alert.addButton(withTitle: "Lock")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .alertFirstButtonReturn else { return }
            Prefs.shared.lockUntil = proposed
            Prefs.shared.enabled = true
            Prefs.shared.flush()
            self.onSave()
            self.refresh()
            self.status.stringValue = "Locked until \(lockStamp(proposed))."
        }
    }
}
