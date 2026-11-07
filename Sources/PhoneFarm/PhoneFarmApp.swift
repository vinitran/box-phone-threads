import SwiftUI

@main
@MainActor
enum PhoneFarmEntryPoint {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--encrypt-threads-key" {
            exit(ThreadsKey.encryptFromTerminal(output: arguments.dropFirst().first))
        }
        PhoneFarmApp.main()
    }
}

struct PhoneFarmApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Phone Farm", id: "devices") {
            RootView(manager: delegate.manager, updater: delegate.updater)
        }
        .defaultSize(width: 1080, height: 720)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager = DeviceManager()
    let updater = AppUpdater()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.stopAll()
    }
}
