import AppKit
import CuktechCore

let args = CommandLine.arguments

if args.contains("--version") {
    print(BuildInfo.version)
    exit(0)
}

if args.contains("--selftest") {
    let settings = AppSettings.load()
    print("[selftest] version=\(BuildInfo.version) channel=\(BuildInfo.channel)")
    print("[selftest] config=\(AppSettings.fileURL.path)")
    print("[selftest] paired=\(settings.isComplete)")
    print("[selftest] mac=\(settings.mac.isEmpty ? "(未设置)" : settings.mac)")
    print("[selftest] tokenBytes=\(settings.tokenBytes?.count ?? 0)")
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller: TrayController

    init(controller: TrayController) {
        self.controller = controller
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.controller.showWizardIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let controller = TrayController(settings: AppSettings.load())
    let delegate = AppDelegate(controller: controller)

    if let demoArg = args.first(where: { $0 == "--wizard-demo" || $0.hasPrefix("--wizard-demo=") }) {
        let screen = demoArg.contains("=")
            ? String(demoArg.split(separator: "=", maxSplits: 1)[1])
            : "welcome"
        DispatchQueue.main.async {
            WizardController.show(settings: AppSettings(), demo: screen)
        }
    } else if args.contains("--panel-demo") {
        DispatchQueue.main.async {
            controller.panel.model.loadDemo()
            controller.panel.model.pinned = true
            controller.panel.show(relativeTo: nil)
        }
    } else {
        app.delegate = delegate
    }
    app.run()
}
