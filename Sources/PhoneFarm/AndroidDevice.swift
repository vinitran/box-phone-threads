import Foundation

struct AndroidDevice: Identifiable {
    let serial: String
    let name: String
    let status: String

    var id: String { serial }
    var isReady: Bool { status == "device" }

    var statusLabel: String {
        switch status {
        case "device": return "Sẵn sàng"
        case "unauthorized": return "Chờ cấp quyền"
        case "offline": return "Ngoại tuyến"
        case "no permissions": return "Thiếu quyền truy cập"
        default: return status
        }
    }

    static func parseList(_ output: String) -> [AndroidDevice]? {
        let lines = output.split(whereSeparator: \.isNewline)
        guard let header = lines.firstIndex(where: { $0 == "List of devices attached" }) else {
            return nil
        }
        return lines.dropFirst(header + 1).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0] != "*" else { return nil }

            let serial = String(fields[0])
            let status = fields.dropFirst().starts(with: ["no", "permissions"])
                ? "no permissions" : String(fields[1])
            let model = fields.dropFirst(2).first(where: { $0.hasPrefix("model:") })
                .map { String($0.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ") }

            return AndroidDevice(serial: serial, name: model ?? serial, status: status)
        }
        .sorted { $0.serial < $1.serial }
    }
}
