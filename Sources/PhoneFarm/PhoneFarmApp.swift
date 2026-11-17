import SwiftUI

@main
@MainActor
enum PhoneFarmEntryPoint {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--encrypt-threads-key" {
            exit(ThreadsKey.encryptFromTerminal(output: arguments.dropFirst().first))
        }
        do {
            if let request = try AutomaticLaunchRequest.parse(arguments) {
                try ThreadsKey.unlockFromStandardInput()
                AutomaticLaunch.request = request
            }
        } catch {
            FileHandle.standardError.write(Data("Không khởi chạy tự động: tham số hoặc mật khẩu mở app không hợp lệ.\n".utf8))
            exit(1)
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
    private var automaticTask: Task<Void, Never>?
    private var awakeProcess: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let request = AutomaticLaunch.request else { return }
        let awake = Process()
        awake.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        awake.arguments = ["-is", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        awake.standardInput = FileHandle.nullDevice
        awake.standardOutput = FileHandle.nullDevice
        awake.standardError = FileHandle.nullDevice
        try? awake.run()
        awakeProcess = awake
        automaticTask = Task { await AutomaticLaunch.run(request, manager: manager) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        automaticTask?.cancel()
        if awakeProcess?.isRunning == true { awakeProcess?.terminate() }
        manager.stopAll()
    }
}
