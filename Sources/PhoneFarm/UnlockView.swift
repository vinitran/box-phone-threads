import SwiftUI

/// Shows the password prompt until the encrypted AI key is unlocked, then the device grid.
struct RootView: View {
    let manager: DeviceManager
    @State private var locked = ThreadsKey.needsUnlock

    var body: some View {
        if locked {
            UnlockView { locked = false }
        } else {
            DevicesView(manager: manager)
        }
    }
}

struct UnlockView: View {
    let onUnlock: () -> Void
    @State private var password = ""
    @State private var error: String?
    @State private var isWorking = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 56, height: 56)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)

            Text("Phone Farm đang khóa").font(.title2.weight(.semibold))
            Text("Nhập mật khẩu để giải mã khóa AI và mở app.")
                .foregroundStyle(.secondary)

            SecureField("Mật khẩu", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .focused($focused)
                .disabled(isWorking)
                .onSubmit(unlock)
                .padding(.top, 6)

            Text(error ?? " ")
                .font(.callout)
                .foregroundStyle(.red)
                .accessibilityHidden(error == nil)

            Button(action: unlock) {
                HStack(spacing: 6) {
                    if isWorking { ProgressView().controlSize(.small) }
                    Text(isWorking ? "Đang mở khóa…" : "Mở khóa")
                }
                .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(password.isEmpty || isWorking)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 760, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focused = true }
    }

    private func unlock() {
        guard !password.isEmpty, !isWorking else { return }
        isWorking = true
        error = nil
        let attempt = password
        Task {
            do {
                try await ThreadsKey.unlock(password: attempt)
                onUnlock()
            } catch {
                self.error = error.localizedDescription
                password = ""
                isWorking = false
                focused = true
            }
        }
    }
}
