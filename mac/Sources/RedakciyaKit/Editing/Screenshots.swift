import AppKit
import ZamazkaKit

/// Zamazka on screenshots, inside Redakciya (part of Editing). If the standalone Zamazka is running, it
/// keeps doing the job and Redakciya stays out of the way: two apps must not redact the same picture.
@MainActor
final class Screenshots {
    static let standaloneID = "com.vldvr.zamazka"
    private var observers: [NSObjectProtocol] = []
    var onChange: () -> Void = {}

    var standaloneRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.standaloneID).isEmpty
    }

    var running: Bool { ZamazkaEmbedded.isRunning }

    func install(anchorScreen: @escaping () -> NSScreen?, anchorFrame: @escaping () -> CGRect?) {
        ZamazkaEmbedded.anchorScreen = anchorScreen
        ZamazkaEmbedded.anchorFrame = anchorFrame
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Screenshots.standaloneID else { return }
                MainActor.assumeIsolated { self?.apply() }
            })
        }
        apply()
    }

    /// Runs Zamazka here when it is turned on and the standalone app is not running.
    func apply() {
        let should = Prefs.shared.screenshotsEnabled && !standaloneRunning
        if should, !running {
            ZamazkaEmbedded.start()
            Log.write("screenshots: on")
        } else if !should, running {
            ZamazkaEmbedded.stop()
            Log.write("screenshots: off\(standaloneRunning ? ", standalone Zamazka is running" : "")")
        }
        onChange()
    }

    /// «Проверять скриншоты здесь»: asks the standalone Zamazka to quit; it saves its state as on ⌘Q.
    func quitStandalone() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.standaloneID) { app.terminate() }
    }

    /// The menu section: Zamazka's own items, or a line about the standalone app.
    func addMenuItems(to menu: NSMenu, target: AnyObject, quitStandalone: Selector, turnOn: Selector) {
        if !Prefs.shared.screenshotsEnabled {
            return
        }
        if standaloneRunning {
            let it = NSMenuItem(title: "Скриншоты проверяет Замазка", action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
            let q = NSMenuItem(title: "Проверять скриншоты здесь", action: quitStandalone, keyEquivalent: "")
            q.target = target
            menu.addItem(q)
            return
        }
        ZamazkaEmbedded.addMenuItems(to: menu)
    }
}
