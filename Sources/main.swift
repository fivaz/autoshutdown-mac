import AppKit

// MARK: - Date helpers

let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

let clockFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm"
    return f
}()

let lockFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
}()

func dayKey(_ date: Date = Date()) -> String { dayFormatter.string(from: date) }
func clock(_ date: Date) -> String { clockFormatter.string(from: date) }
func lockStamp(_ date: Date) -> String { lockFormatter.string(from: date) }

func formatRemaining(_ seconds: TimeInterval) -> String {
    let t = max(0, Int(seconds.rounded()))
    if t >= 3600 { return "\(t / 3600)h\(String(format: "%02d", (t % 3600) / 60))" }
    if t >= 60 { return "\(t / 60)m" }
    return "\(t)s"
}

// MARK: - Preferences

enum Key {
    static let hour = "shutdownHour"
    static let minute = "shutdownMinute"
    static let enabled = "enabled"
    static let extensionDay = "extensionUsedDay"
    static let overrideDay = "overrideDay"
    static let overrideTime = "overrideTime"
    static let handledDay = "handledDay"
    static let lockUntil = "lockUntil"
    static let firstRunDone = "firstRunDone"
}

final class Prefs {
    static let shared = Prefs()
    private let store = UserDefaults.standard

    private init() {
        store.register(defaults: [Key.hour: 23, Key.minute: 0, Key.enabled: true])
    }

    var hour: Int {
        get { store.integer(forKey: Key.hour) }
        set { store.set(newValue, forKey: Key.hour) }
    }

    var minute: Int {
        get { store.integer(forKey: Key.minute) }
        set { store.set(newValue, forKey: Key.minute) }
    }

    var enabled: Bool {
        get { store.bool(forKey: Key.enabled) }
        set { store.set(newValue, forKey: Key.enabled) }
    }

    /// The single +15 min grant is per calendar day.
    var extensionUsedToday: Bool { store.string(forKey: Key.extensionDay) == dayKey() }
    func markExtensionUsed() { store.set(dayKey(), forKey: Key.extensionDay) }

    /// Today's effective deadline when it differs from the configured time.
    var overrideToday: Date? {
        get {
            guard store.string(forKey: Key.overrideDay) == dayKey() else { return nil }
            return store.object(forKey: Key.overrideTime) as? Date
        }
        set {
            if let value = newValue {
                store.set(dayKey(), forKey: Key.overrideDay)
                store.set(value, forKey: Key.overrideTime)
            } else {
                store.removeObject(forKey: Key.overrideDay)
                store.removeObject(forKey: Key.overrideTime)
            }
        }
    }

    /// Marks a day whose deadline has already been dealt with (or missed by too much).
    var handledDay: String? {
        get { store.string(forKey: Key.handledDay) }
        set { store.set(newValue, forKey: Key.handledDay) }
    }

    /// A commitment window. While it is open the settings can only be made stricter.
    var lockUntil: Date? {
        get {
            guard let date = store.object(forKey: Key.lockUntil) as? Date, date > Date() else { return nil }
            return date
        }
        set {
            if let value = newValue { store.set(value, forKey: Key.lockUntil) }
            else { store.removeObject(forKey: Key.lockUntil) }
        }
    }

    var isLocked: Bool { lockUntil != nil }

    var firstRunDone: Bool {
        get { store.bool(forKey: Key.firstRunDone) }
        set { store.set(newValue, forKey: Key.firstRunDone) }
    }

    /// Writes pending changes to disk. Called before a shutdown, which cuts the usual flush short.
    func flush() { store.synchronize() }
}

// MARK: - Schedule

/// The configured shutdown moment on the calendar day containing `date`.
func baseTarget(on date: Date) -> Date {
    let cal = Calendar.current
    var comps = cal.dateComponents([.year, .month, .day], from: date)
    comps.hour = Prefs.shared.hour
    comps.minute = Prefs.shared.minute
    comps.second = 0
    return cal.date(from: comps) ?? date
}

/// Today's effective deadline: the override if one is set for today, otherwise the configured time.
func todayTarget() -> Date { Prefs.shared.overrideToday ?? baseTarget(on: Date()) }

/// The next moment `hour:minute` comes round, today or tomorrow.
/// Used to compare two candidate times honestly: at 20:00, 00:30 is later than 23:00, not earlier.
func nextOccurrence(hour: Int, minute: Int, from now: Date = Date()) -> Date {
    let cal = Calendar.current
    var comps = cal.dateComponents([.year, .month, .day], from: now)
    comps.hour = hour
    comps.minute = minute
    comps.second = 0
    let today = cal.date(from: comps) ?? now
    return today > now ? today : today.addingTimeInterval(86_400)
}

/// The next deadline to display (today's if still ahead, otherwise tomorrow's).
func nextTarget() -> Date {
    let t = todayTarget()
    if t > Date() { return t }
    return baseTarget(on: Date().addingTimeInterval(86_400))
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let warning = WarningPanel()
    private var settings: SettingsWindowController?
    private var timer: Timer?

    /// Warning thresholds in seconds, descending.
    private let thresholds = [900, 300, 60, 30]
    private var fired = Set<Int>()
    private var overdueArmed = false
    private var shuttingDown = false
    /// nil until the first check comes back.
    private var automationGranted: Bool?

    /// How long after a missed deadline the app still insists on shutting down.
    private let graceWindow: TimeInterval = 2 * 3600

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "power", accessibilityDescription: "AutoShutdown")
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        tick()
        checkAutomationPermission()
        performFirstRunSetup()
    }

    /// Dragging the app to Applications is the whole installation, so the app
    /// registers its own login item the first time it is opened.
    private func performFirstRunSetup() {
        guard !Prefs.shared.firstRunDone else { return }
        Prefs.shared.firstRunDone = true
        if LoginItem.conflictingAgent == nil {
            LoginItem.setEnabled(true)
        }
        Prefs.shared.flush()
        openSettings()
    }

    @objc private func systemDidWake() { tick() }

    // MARK: Automation permission

    /// Under the hardened runtime the shutdown needs permission to control System Events.
    /// Asking for it at launch means the prompt appears while you are sitting there,
    /// rather than at 23:00 when the shutdown would silently fail.
    @objc func checkAutomationPermission() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "tell application \"System Events\" to get name"]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do { try task.run() } catch {
                DispatchQueue.main.async { self?.automationGranted = false }
                return
            }
            task.waitUntilExit()
            let granted = task.terminationStatus == 0
            DispatchQueue.main.async { self?.automationGranted = granted }
        }
    }

    @objc func openAutomationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
        // Re-check shortly after, so the menu clears itself once permission is given.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.checkAutomationPermission()
        }
    }

    // MARK: Tick

    private func tick() {
        guard !shuttingDown else { return }

        guard Prefs.shared.enabled else {
            statusItem.button?.title = " off"
            return
        }

        let now = Date()
        let target = todayTarget()
        let remaining = target.timeIntervalSince(now)

        if remaining <= 0 {
            let missedByTooMuch = remaining <= -graceWindow
            let alreadyHandled = Prefs.shared.handledDay == dayKey()

            if !alreadyHandled && !missedByTooMuch {
                // Woke up well past the deadline: give a 60 second countdown first.
                if remaining < -5 && !overdueArmed {
                    overdueArmed = true
                    Prefs.shared.overrideToday = now.addingTimeInterval(60)
                    fired.removeAll()
                    statusItem.button?.title = " 60s"
                    return
                }
                performShutdown()
                return
            }

            Prefs.shared.handledDay = dayKey()
            fired.removeAll()
            overdueArmed = false
            statusItem.button?.title = " " + formatRemaining(nextTarget().timeIntervalSince(now))
            return
        }

        statusItem.button?.title = " " + formatRemaining(remaining)
        checkWarnings(remaining: remaining)
    }

    private func checkWarnings(remaining: TimeInterval) {
        for threshold in thresholds {
            guard remaining <= Double(threshold) else { continue }
            if !fired.contains(threshold) {
                // Skipped thresholds (sleep, clock jumps) count as fired.
                for higher in thresholds where higher >= threshold { fired.insert(higher) }
                showWarning(threshold: threshold)
            }
            return
        }
    }

    private func showWarning(threshold: Int) {
        let label: String
        switch threshold {
        case 900: label = "15 minutes"
        case 300: label = "5 minutes"
        case 60:  label = "1 minute"
        default:  label = "30 seconds"
        }

        let canExtend = threshold >= 60 && !Prefs.shared.extensionUsedToday
        let detail: String
        if canExtend {
            detail = "Shutting down at \(clock(todayTarget())). You can add 15 minutes once today."
        } else if threshold >= 60 {
            detail = "Shutting down at \(clock(todayTarget())). No extensions left today."
        } else {
            detail = "Save your work now."
        }

        NSSound.beep()
        warning.show(
            headline: "Your Mac shuts down in \(label)",
            detail: detail,
            allowExtend: canExtend,
            extendHandler: { [weak self] in self?.addFifteen() })
    }

    // MARK: Actions

    @objc func addFifteen() {
        guard Prefs.shared.enabled, !Prefs.shared.extensionUsedToday else { return }
        let target = todayTarget()
        guard target > Date() else { return }

        Prefs.shared.overrideToday = target.addingTimeInterval(15 * 60)
        Prefs.shared.markExtensionUsed()
        fired.removeAll()
        warning.close()
        tick()
    }

    @objc func openSettings() {
        if settings == nil { settings = SettingsWindowController(onSave: { [weak self] in self?.afterSettingsChange() }) }
        NSApp.activate(ignoringOtherApps: true)
        settings?.show()
    }

    private func afterSettingsChange() {
        fired.removeAll()
        overdueArmed = false
        tick()
    }

    @objc func toggleEnabled() {
        // A lock keeps the app switched on; turning it off would be the easiest escape.
        guard !(Prefs.shared.isLocked && Prefs.shared.enabled) else { return }
        Prefs.shared.enabled.toggle()
        fired.removeAll()
        overdueArmed = false
        tick()
    }

    @objc func quit() { NSApp.terminate(nil) }

    private func performShutdown() {
        shuttingDown = true
        warning.close()
        // Recorded and flushed before the machine goes down, so that turning the Mac
        // back on later the same evening does not trigger a second shutdown.
        Prefs.shared.handledDay = dayKey()
        Prefs.shared.flush()

        // Launch with AUTOSHUTDOWN_DRY_RUN=1 to rehearse without powering off.
        if ProcessInfo.processInfo.environment["AUTOSHUTDOWN_DRY_RUN"] == "1" {
            warning.show(headline: "Dry run: your Mac would shut down now",
                         detail: "Set AUTOSHUTDOWN_DRY_RUN=0 for the real thing.",
                         allowExtend: false, extendHandler: nil)
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"System Events\" to shut down"]
        try? task.run()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let configured = String(format: "%02d:%02d", Prefs.shared.hour, Prefs.shared.minute)
        menu.addItem(disabledItem("Daily shutdown at \(configured)"))

        if Prefs.shared.enabled {
            let target = nextTarget()
            let sameDay = Calendar.current.isDateInToday(target)
            let when = sameDay ? "Today \(clock(target))" : "Tomorrow \(clock(target))"
            let left = formatRemaining(target.timeIntervalSinceNow)
            menu.addItem(disabledItem("Next: \(when)  (in \(left))"))
        } else {
            menu.addItem(disabledItem("Disabled"))
        }

        menu.addItem(.separator())

        let extend = NSMenuItem(title: "Add 15 minutes", action: #selector(addFifteen), keyEquivalent: "e")
        extend.target = self
        extend.isEnabled = Prefs.shared.enabled && !Prefs.shared.extensionUsedToday && todayTarget() > Date()
        menu.addItem(extend)
        if Prefs.shared.extensionUsedToday {
            menu.addItem(disabledItem("Extension already used today"))
        }

        if let stale = LoginItem.conflictingAgent {
            menu.addItem(.separator())
            menu.addItem(disabledItem("⚠ Old login item still installed"))
            menu.addItem(disabledItem(stale.path))
            menu.addItem(disabledItem("Run uninstall.sh from the project to clear it"))
        }

        if automationGranted == false {
            menu.addItem(.separator())
            let fix = NSMenuItem(title: "⚠ Allow control of System Events…",
                                 action: #selector(openAutomationSettings), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
            menu.addItem(disabledItem("Without it the shutdown cannot run"))
        }

        menu.addItem(.separator())

        if let lock = Prefs.shared.lockUntil {
            menu.addItem(disabledItem("Locked until \(lockStamp(lock))"))
        }

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let toggle = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = Prefs.shared.enabled ? .on : .off
        toggle.isEnabled = !(Prefs.shared.isLocked && Prefs.shared.enabled)
        menu.addItem(toggle)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit AutoShutdown", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

// MARK: - Entry point

// uninstall.sh calls this so the login item is withdrawn before the bundle is deleted,
// which is what stops a ghost entry appearing in System Settings > Login Items.
if CommandLine.arguments.contains("--unregister-login-item") {
    LoginItem.setEnabled(false)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
