import SwiftUI

struct ProxySheet: View {
    let device: AndroidDevice
    var onActivity: (String) -> Void = { _ in }
    var onSaved: () -> Void = {}
    /// Proxy line from the phone's identity file; used before the Mac's saved proxy.
    var phoneProxy: String? = nil
    /// Called with the applied proxy line, or nil after removing it, to update the phone's file.
    var onApplied: (String?) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var savedProxy: PhoneFarmStore.SavedProxy?
    @State private var isWorking = false
    @State private var status = ""
    @State private var error: String?
    @State private var fromPhone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Proxy · \(device.name)").font(.title2.weight(.semibold))
            Text(fromPhone ? "host:port:user:pass hoặc host:port · đang hiển thị proxy lưu trên điện thoại"
                           : "host:port:user:pass hoặc host:port")
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
                if fromPhone || (savedProxy.map { $0.mode != "off" } ?? false) {
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
            if let phoneProxy = phoneProxy?.trimmingCharacters(in: .whitespacesAndNewlines), !phoneProxy.isEmpty {
                input = phoneProxy
                fromPhone = true
                return
            }
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

    /// Checks the proxy from the Mac, saves it on the Mac and on the phone; the phone's USB tunnel
    /// then restarts through it (onApplied).
    private func apply() async {
        guard !isWorking else { return }
        guard let profile = ProxyProfile(line: input) else {
            error = "Nhập proxy dạng host:port:user:pass hoặc host:port."
            return
        }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            report("Đang kiểm tra proxy")
            let ip = try await ProxyTester.publicIP(through: profile)
            report("Đang lưu proxy")
            try PhoneFarmStore.shared.get().saveTunnelProxy(profile, device: device)
            onSaved()
            onApplied(input.trimmingCharacters(in: .whitespacesAndNewlines))
            report("Proxy đã lưu · \(profile.endpoint.address) · IP \(ip) · đang nối lại internet qua cáp")
            dismiss()
        } catch {
            self.error = error.localizedDescription
            report("Chưa áp dụng được proxy · " + error.localizedDescription)
        }
    }

    private func remove() async {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            report("Đang gỡ proxy")
            try PhoneFarmStore.shared.get().saveProxy(.off, device: device)
            onSaved()
            onApplied(nil)
            report("Đã gỡ proxy · điện thoại dùng mạng của Mac qua cáp")
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
