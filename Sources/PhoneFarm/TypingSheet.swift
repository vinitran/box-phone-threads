import SwiftUI

struct TypingSheet: View {
    let device: AndroidDevice
    var onActivity: (DeviceProgress) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var keyboard: KeyboardCapture?
    @State private var points: [Character: CGPoint] = [:]
    @State private var operation: Task<Void, Never>?
    @State private var isTyping = false
    @State private var done = 0
    @State private var total = 0
    @State private var status = ""
    @State private var minimumDelay = 60
    @State private var maximumDelay = 140

    private var nextKey: Character? {
        let anchors = KeyboardLayout.anchors + (text.contains(where: \.isNewline) ? [KeyboardLayout.enter] : [])
        return anchors.first { points[$0] == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gõ Telex trên \(device.name)").font(.title2.weight(.semibold))
            Text("Mở ô nhập và chọn Gboard tiếng Việt Telex với bàn phím dọc. Tắt tự viết hoa và tự sửa nếu cần giữ nguyên từng ký tự.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Đoạn văn").font(.headline)
                    TextEditor(text: $text)
                        .accessibilityLabel("Đoạn văn")
                        .padding(4)
                        .frame(height: 230)
                        .border(.secondary.opacity(0.3))
                        .disabled(operation != nil)
                }
                .frame(width: 350)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Bàn phím điện thoại").font(.headline)
                    if let keyboard {
                        keyboardImage(keyboard)
                            .frame(width: 290, height: 206)
                        Text(nextKey.map { "Bấm giữa phím \(label($0)) trong ảnh." } ?? "Đã xác định vị trí các phím.")
                            .font(.callout)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "keyboard").font(.title)
                            Text("Phone Farm tự đọc vị trí phím từ Android khi bắt đầu gõ.")
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.secondary)
                        .frame(width: 290, height: 230)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Khoảng nghỉ ngẫu nhiên giữa các phím").font(.headline)
                HStack(spacing: 20) {
                    Stepper("Tối thiểu \(minimumDelay) ms", value: $minimumDelay,
                            in: 30...maximumDelay, step: 10)
                    Stepper("Tối đa \(maximumDelay) ms", value: $maximumDelay,
                            in: minimumDelay...1_000, step: 10)
                }
                .fixedSize()
            }
            .disabled(operation != nil)

            if total > 0 {
                ProgressView(value: Double(done), total: Double(total)) {
                    Text("\(done)/\(total) lần chạm")
                }
            }
            if !status.isEmpty {
                Text(status).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if keyboard != nil {
                    Button("Thử đọc lại bàn phím") {
                        keyboard = nil
                        points = [:]
                        status = ""
                    }
                    .disabled(operation != nil)
                }
                Spacer()
                if isTyping {
                    Button("Dừng") { operation?.cancel() }
                }
                Button("Đóng") { dismiss() }
                    .disabled(operation != nil)
                    .keyboardShortcut(.cancelAction)
                Button("Bắt đầu gõ", action: start)
                    .buttonStyle(.borderedProminent)
                    .disabled(operation != nil || (keyboard != nil && nextKey != nil) || text.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 700)
        .interactiveDismissDisabled(operation != nil)
        .onDisappear { operation?.cancel() }
        .onChange(of: status) { value in
            if !value.isEmpty { onActivity(DeviceProgress(message: value)) }
        }
    }

    private func keyboardImage(_ keyboard: KeyboardCapture) -> some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / CGFloat(keyboard.image.width),
                            geometry.size.height / CGFloat(keyboard.image.height))
            ZStack(alignment: .topLeading) {
                Image(decorative: keyboard.image, scale: 1)
                    .resizable()
                    .frame(width: CGFloat(keyboard.image.width) * scale,
                           height: CGFloat(keyboard.image.height) * scale)
                ForEach(Array(points.keys), id: \.self) { key in
                    if let point = points[key] {
                        Circle()
                            .fill(.orange)
                            .frame(width: 8, height: 8)
                            .position(x: (point.x - keyboard.context.frame.minX) * scale,
                                      y: (point.y - keyboard.context.frame.minY) * scale)
                    }
                }
            }
            .frame(width: CGFloat(keyboard.image.width) * scale,
                   height: CGFloat(keyboard.image.height) * scale)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { tap in
                guard operation == nil, let key = nextKey else { return }
                points[key] = CGPoint(x: tap.location.x / scale + keyboard.context.frame.minX,
                                      y: tap.location.y / scale + keyboard.context.frame.minY)
            })
        }
    }

    private func label(_ key: Character) -> String {
        switch key {
        case " ": return "cách"
        case "\n": return "xuống dòng (↵)"
        default: return "“\(key.uppercased())”"
        }
    }

    private func start() {
        isTyping = true
        operation = Task {
            defer {
                isTyping = false
                operation = nil
            }
            done = 0
            total = 0
            status = ""
            do {
                let keys = try Telex.keys(for: text)
                guard let adb = ToolPaths.adb() else { throw TypingError.unavailable }
                let typing = TelexTyping(adb: adb, serial: device.serial)
                let context = try await typing.prepare(for: keys)
                let taps: [CGPoint]
                let usesSystemKeyboard = keyboard == nil
                if let keyboard {
                    guard keyboard.context == context else {
                        self.keyboard = nil
                        points = [:]
                        throw TypingError.keyboardChanged
                    }
                    taps = try KeyboardLayout(points: points).taps(for: keys)
                } else {
                    status = "Đang đọc vị trí phím từ Android…"
                    guard let systemTaps = try await typing.systemTaps(for: keys, context: context) else {
                        keyboard = try await typing.capture(context: context)
                        points = [:]
                        status = "Android không trả đủ vị trí phím. Hãy đánh dấu các phím trên ảnh để tiếp tục."
                        return
                    }
                    taps = systemTaps
                }
                defer {
                    keyboard = nil
                    points = [:]
                }
                status = ""
                let reportProgress: @MainActor @Sendable (Int, Int) -> Void = {
                    done = $0
                    total = $1
                    onActivity(DeviceProgress(message: "Đang gõ Telex · \($0)/\($1) phím", completed: $0, total: $1))
                }
                if usesSystemKeyboard {
                    try await typing.typeText(text, context: context,
                                              pauseMilliseconds: minimumDelay...maximumDelay, progress: reportProgress)
                } else {
                    try await typing.type(taps, context: context,
                                          pauseMilliseconds: minimumDelay...maximumDelay, progress: reportProgress)
                }
                status = "Đã gõ xong."
            } catch is CancellationError {
                status = "Đã dừng gõ."
            } catch {
                status = error.localizedDescription
            }
        }
    }
}
