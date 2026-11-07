import SwiftUI

struct ProxySheet: View {
    let device: AndroidDevice
    var onActivity: (String) -> Void = { _ in }
    var onSaved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var savedProxy: PhoneFarmStore.SavedProxy?
    @State private var isWorking = false
    @State private var status = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Proxy · \(device.name)").font(.title2.weight(.semibold))
            Text("host:port:user:pass hoặc host:port")
                .font(.callout).foregroundStyle(.secondary)
            SecureField("Nhập hoặc dán proxy", text: $input)
                .textFieldStyle(.roundedBorder)
                .disabled(isWorking)
                .onSubmit { if !isWorking { Task { await apply() } } }
            if isWorking {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(status).font(.callout)
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let savedProxy, savedProxy.mode != "off" {
                    Button("Gỡ proxy", role: .destructive) { Task { await remove() } }
                }
                Spacer()
                Button("Đóng") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Áp dụng") { Task { await apply() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(isWorking)
        }
        .padding(22)
        .frame(width: 470)
        .interactiveDismissDisabled(isWorking)
        .task { loadSaved() }
    }

    private func loadSaved() {
        do {
            savedProxy = try PhoneFarmStore.shared.get().savedProxy(serial: device.serial)
            guard let savedProxy, let endpoint = savedProxy.endpoint else { return }
            var value = endpoint.address
            if let reference = savedProxy.credentialID {
                let login = try ProxyPasswords.load(reference)
                value += ":" + login.username + ":" + login.password
            }
            input = value
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func report(_ message: String) {
        status = message
        onActivity(message)
    }

    private func apply() async {
        guard !isWorking else { return }
        guard let profile = ProxyProfile(line: input) else {
            error = "Nhập proxy dạng host:port:user:pass hoặc host:port."
            return
        }
        guard let adb = ToolPaths.adb() else { error = ProxyError.noADB.localizedDescription; return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        let proxy = AndroidProxy(adb: adb, serial: device.serial)
        let relay = AndroidProxyRelay(adb: adb, serial: device.serial)
        var created: AndroidProxyRelay.Handle?
        var previous: ProxyConfiguration?
        var target: ProxyConfiguration?
        var applying = false
        do {
            let store = try PhoneFarmStore.shared.get()
            let oldSaved = try store.savedProxy(serial: device.serial)
            let before = try await proxy.configuration()
            previous = before
            guard before.address != nil else { throw ProxyError.changed }
            report("Đang xác thực proxy")
            let endpoint: ProxyEndpoint
            if profile.login != nil {
                let handle = try await relay.start(profile)
                created = handle
                endpoint = handle.endpoint
            } else {
                endpoint = profile.endpoint
            }
            let ip = try await proxy.validate(endpoint)
            let configuration = ProxyConfiguration.direct(endpoint)
            target = configuration
            report("Đang áp dụng và lưu proxy")
            applying = true
            try await proxy.apply(configuration, replacing: before)
            do {
                if let created { try store.saveAuthenticatedProxy(profile, handle: created, device: device) }
                else { try store.saveProxy(configuration, device: device) }
            } catch {
                try await proxy.apply(before, replacing: configuration)
                applying = false
                throw error
            }
            onSaved()
            if let oldDirectory = oldSaved?.relayDirectory, oldDirectory != created?.directory {
                try? await relay.stop(directory: oldDirectory)
            }
            report("Proxy đã áp dụng · \(profile.endpoint.address) · IP \(ip)")
            dismiss()
        } catch {
            var canStop = !applying
            if applying, let target, let previous {
                do {
                    let current = try await proxy.configuration()
                    if current == target { try await proxy.apply(previous, replacing: target) }
                    canStop = true
                } catch {
                    canStop = false
                }
            }
            if canStop, let created { try? await relay.stop(directory: created.directory) }
            self.error = error.localizedDescription
            report("Chưa áp dụng được proxy · " + error.localizedDescription)
        }
    }

    private func remove() async {
        guard !isWorking, let adb = ToolPaths.adb() else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let proxy = AndroidProxy(adb: adb, serial: device.serial)
            let store = try PhoneFarmStore.shared.get()
            let saved = try store.savedProxy(serial: device.serial)
            let previous = try await proxy.configuration()
            report("Đang gỡ proxy")
            try await proxy.apply(.off, replacing: previous)
            try store.saveProxy(.off, device: device)
            if let directory = saved?.relayDirectory {
                try? await AndroidProxyRelay(adb: adb, serial: device.serial).stop(directory: directory)
            }
            onSaved()
            report("Đã gỡ proxy")
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
