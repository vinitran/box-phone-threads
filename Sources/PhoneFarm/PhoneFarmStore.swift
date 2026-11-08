import Foundation
import SQLite3

@MainActor
final class PhoneFarmStore {
    static let shared: Result<PhoneFarmStore, Error> = Result { try PhoneFarmStore() }
    static var databaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Phone Farm", isDirectory: true)
            .appendingPathComponent("phone-farm.sqlite3")
    }

    struct SavedProxy {
        let endpoint: ProxyEndpoint?
        let mode: String
        let updatedAt: String
        let username: String?
        /// Stored as plain text: only the AI key is encrypted.
        let password: String?

        var isActive: Bool { mode != "off" && mode != "unsupported" && endpoint != nil }

        /// The saved proxy, or nil when it has a login without a password (saved in the Keychain by
        /// older versions, which this version no longer reads).
        var profile: ProxyProfile? {
            guard isActive, let endpoint else { return nil }
            guard let username, !username.isEmpty else {
                return ProxyProfile(host: endpoint.host, port: String(endpoint.port))
            }
            guard let password else { return nil }
            return ProxyProfile(host: endpoint.host, port: String(endpoint.port), username: username, password: password)
        }
    }

    struct Run: Identifiable {
        let id: String
        let startedAt: String
        let finishedAt: String?
        let state: String
        let message: String
    }

    struct DeviceInfo {
        let name: String
        let lastSeen: String
        let proxy: SavedProxy?
        let runs: [Run]
    }

    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private struct StoreError: LocalizedError {
        let errorDescription: String?
    }

    private init() throws {
        let folder = Self.databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(Self.databaseURL.path, &database,
                              SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = failure()
            sqlite3_close(database)
            database = nil
            throw error
        }
        do {
            sqlite3_busy_timeout(database, 3_000)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.databaseURL.path)
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            let version = try rows("PRAGMA user_version").first?.first ?? nil
            guard ["0", "1", "2", "3", "4"].contains(version ?? "") else {
                throw StoreError(errorDescription: "Cơ sở dữ liệu cần phiên bản Phone Farm mới hơn.")
            }
            try transaction {
                try execute("""
                    CREATE TABLE IF NOT EXISTS devices (
                        serial TEXT PRIMARY KEY, name TEXT NOT NULL,
                        last_status TEXT NOT NULL, last_seen TEXT NOT NULL
                    )
                    """)
                try execute("""
                    CREATE TABLE IF NOT EXISTS proxies (
                        serial TEXT PRIMARY KEY REFERENCES devices(serial),
                        host TEXT, port INTEGER, mode TEXT NOT NULL, updated_at TEXT NOT NULL
                    )
                    """)
                try execute("""
                    CREATE TABLE IF NOT EXISTS runs (
                        id TEXT PRIMARY KEY, serial TEXT NOT NULL REFERENCES devices(serial),
                        started_at TEXT NOT NULL, finished_at TEXT,
                        state TEXT NOT NULL, message TEXT NOT NULL
                    )
                    """)
                try execute("CREATE INDEX IF NOT EXISTS runs_device ON runs(serial, started_at DESC)")
                try execute("""
                    CREATE TABLE IF NOT EXISTS reply_attempts (
                        serial TEXT NOT NULL REFERENCES devices(serial), post_id TEXT NOT NULL,
                        created_at TEXT NOT NULL, PRIMARY KEY(serial, post_id)
                    )
                    """)
                if version == "0" || version == "1" {
                    try execute("ALTER TABLE proxies ADD COLUMN username TEXT")
                    try execute("ALTER TABLE proxies ADD COLUMN credential_id TEXT")
                    try execute("ALTER TABLE proxies ADD COLUMN relay_directory TEXT")
                    try execute("ALTER TABLE proxies ADD COLUMN relay_port INTEGER")
                }
                try execute("CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT NOT NULL)")
                try execute("""
                    CREATE TABLE IF NOT EXISTS comments (
                        id INTEGER PRIMARY KEY, serial TEXT NOT NULL REFERENCES devices(serial),
                        posted_at TEXT NOT NULL
                    )
                    """)
                try execute("CREATE INDEX IF NOT EXISTS comments_posted ON comments(posted_at, serial)")
                if version != "4" {
                    // Runs before version 4 only recorded the send in their summary message.
                    try execute("""
                        INSERT INTO comments(serial, posted_at)
                        SELECT serial, COALESCE(finished_at, started_at) FROM runs
                        WHERE message LIKE '%Đã bấm Đăng 1 lần%'
                        """)
                }
                // Added without a version bump so older Phone Farm versions still open the database.
                if try !rows("PRAGMA table_info(proxies)").contains(where: { $0[1] == "password" }) {
                    try execute("ALTER TABLE proxies ADD COLUMN password TEXT")
                }
                try execute("PRAGMA user_version = 4")
                try execute("""
                    UPDATE runs SET state = 'interrupted', finished_at = ?,
                        message = 'Phiên trước bị gián đoạn trước khi có kết quả.'
                    WHERE state = 'running'
                    """, [now])
            }
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    func threadsSettings() throws -> ThreadsSettings {
        if let value = try rows("SELECT value FROM app_settings WHERE key = 'threads'").first?.first ?? nil {
            var settings = try JSONDecoder().decode(ThreadsSettings.self, from: Data(value.utf8))
            if settings.replyPrompts == nil {
                settings.replyPrompts = try ThreadsSettings.bundledPrompts()
                try saveThreadsSettings(settings)
            }
            return settings
        }
        let settings = try ThreadsSettings.defaults().validated()
        try saveThreadsSettings(settings)
        return settings
    }

    func saveThreadsSettings(_ settings: ThreadsSettings) throws {
        let settings = try settings.validated()
        let value = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        try execute("""
            INSERT INTO app_settings(key, value, updated_at) VALUES('threads', ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
            """, [value, now])
    }

    struct SubmittedPhotos: Codable {
        let batch: ThreadsAttachments.Batch
        let removeAfter: Date
    }

    func setting(_ key: String) throws -> String? {
        try rows("SELECT value FROM app_settings WHERE key = ?", [key]).first?.first ?? nil
    }

    func saveSetting(_ key: String, value: String) throws {
        try execute("INSERT INTO app_settings(key, value, updated_at) VALUES(?, ?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
                    [key, value, now])
    }

    func recordComment(serial: String) throws {
        try execute("INSERT INTO comments(serial, posted_at) VALUES(?, ?)", [serial, now])
    }

    /// Number of submitted comments per serial since the given time.
    func commentCounts(since start: Date) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for row in try rows("SELECT serial, COUNT(*) FROM comments WHERE posted_at >= ? GROUP BY serial",
                            [ISO8601DateFormatter().string(from: start)]) {
            if let serial = row[0], let count = row[1].flatMap({ Int($0) }) { counts[serial] = count }
        }
        return counts
    }

    /// Plaintext key written by older builds; only read to encrypt it, then deleted.
    func legacyAIKey() throws -> String? {
        guard let value = try rows("SELECT value FROM app_settings WHERE key = 'ai-key'").first?.first ?? nil else { return nil }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    func deleteLegacyAIKey() throws {
        try execute("DELETE FROM app_settings WHERE key = 'ai-key'")
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try execute("VACUUM")
    }

    func imageCache(serial: String) throws -> ThreadsAttachments.ImageCache? {
        guard let value = try rows("SELECT value FROM app_settings WHERE key = ?", ["threads-image-cache." + serial]).first?.first ?? nil else { return nil }
        return try JSONDecoder().decode(ThreadsAttachments.ImageCache.self, from: Data(value.utf8))
    }

    func saveImageCache(_ cache: ThreadsAttachments.ImageCache, serial: String) throws {
        guard cache.isValid else { throw StoreError(errorDescription: "Thư mục ảnh trên điện thoại không hợp lệ.") }
        let value = String(decoding: try JSONEncoder().encode(cache), as: UTF8.self)
        try execute("INSERT INTO app_settings(key, value, updated_at) VALUES(?, ?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
                    ["threads-image-cache." + serial, value, now])
    }

    func submittedPhotos(serial: String) throws -> [SubmittedPhotos] {
        guard let value = try rows("SELECT value FROM app_settings WHERE key = ?", ["submitted-photos." + serial]).first?.first ?? nil else { return [] }
        return try JSONDecoder().decode([SubmittedPhotos].self, from: Data(value.utf8))
    }

    func queueSubmittedPhotos(_ batch: ThreadsAttachments.Batch, serial: String, submittedAt: Date = Date()) throws {
        guard batch.isDisposable else { return }
        var photos = try submittedPhotos(serial: serial)
        photos.removeAll { $0.batch.album == batch.album }
        photos.append(.init(batch: batch, removeAfter: submittedAt.addingTimeInterval(20 * 60)))
        try saveSubmittedPhotos(photos, serial: serial)
    }

    func removeSubmittedPhotos(album: String, serial: String) throws {
        try saveSubmittedPhotos(submittedPhotos(serial: serial).filter { $0.batch.album != album }, serial: serial)
    }

    private func saveSubmittedPhotos(_ photos: [SubmittedPhotos], serial: String) throws {
        let value = String(decoding: try JSONEncoder().encode(photos), as: UTF8.self)
        try execute("INSERT INTO app_settings(key, value, updated_at) VALUES(?, ?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
                    ["submitted-photos." + serial, value, now])
    }

    func remember(_ devices: [AndroidDevice]) throws {
        guard !devices.isEmpty else { return }
        try transaction {
            for device in devices { try remember(device) }
        }
    }

    private func remember(_ device: AndroidDevice) throws {
        try execute("""
            INSERT INTO devices(serial, name, last_status, last_seen) VALUES(?, ?, ?, ?)
            ON CONFLICT(serial) DO UPDATE SET
                name = excluded.name, last_status = excluded.last_status, last_seen = excluded.last_seen
            """, [device.serial, device.name, device.status, now])
    }

    func devices() throws -> [AndroidDevice] {
        try rows("SELECT serial, name FROM devices ORDER BY serial").map {
            AndroidDevice(serial: $0[0]!, name: $0[1]!, status: "offline")
        }
    }

    func savedProxy(serial: String) throws -> SavedProxy? {
        guard let row = try rows("""
            SELECT host, port, mode, updated_at, username, password FROM proxies WHERE serial = ?
            """, [serial]).first
        else { return nil }
        let endpoint = ProxyEndpoint(host: row[0] ?? "", port: row[1] ?? "")
        return SavedProxy(endpoint: endpoint, mode: row[2]!, updatedAt: row[3]!, username: row[4], password: row[5])
    }

    /// Saves the proxy the phone's USB tunnel goes through.
    func saveProxy(_ profile: ProxyProfile, device: AndroidDevice) throws {
        try transaction {
            try remember(device)
            try execute("""
                INSERT INTO proxies(serial, host, port, mode, updated_at, username, password)
                VALUES(?, ?, ?, 'tunnel', ?, ?, ?)
                ON CONFLICT(serial) DO UPDATE SET
                    host = excluded.host, port = excluded.port, mode = excluded.mode,
                    updated_at = excluded.updated_at, username = excluded.username, password = excluded.password,
                    credential_id = NULL, relay_directory = NULL, relay_port = NULL
                """, [device.serial, profile.endpoint.host, String(profile.endpoint.port), now,
                      profile.login?.username, profile.login?.password])
        }
    }

    func removeProxy(device: AndroidDevice) throws {
        try execute("""
            UPDATE proxies SET mode = 'off', updated_at = ?, username = NULL, password = NULL,
                credential_id = NULL, relay_directory = NULL, relay_port = NULL
            WHERE serial = ?
            """, [now, device.serial])
    }

    func startRun(device: AndroidDevice) throws -> String {
        let id = UUID().uuidString
        try transaction {
            try remember(device)
            try execute("INSERT INTO runs(id, serial, started_at, state, message) VALUES(?, ?, ?, 'running', ?)",
                        [id, device.serial, now, "Đang mở Threads"])
        }
        return id
    }

    func finishRun(id: String, message: String, hasIssue: Bool) throws {
        try execute("UPDATE runs SET finished_at = ?, state = ?, message = ? WHERE id = ?",
                    [now, hasIssue ? "issue" : "completed", message, id])
    }

    func deviceInfo(serial: String) throws -> DeviceInfo? {
        guard let device = try rows("SELECT name, last_seen FROM devices WHERE serial = ?", [serial]).first else { return nil }
        let runs = try rows("""
            SELECT id, started_at, finished_at, state, message FROM runs
            WHERE serial = ? ORDER BY started_at DESC, rowid DESC LIMIT 20
            """, [serial]).map {
                Run(id: $0[0]!, startedAt: $0[1]!, finishedAt: $0[2], state: $0[3]!, message: $0[4]!)
            }
        return DeviceInfo(name: device[0]!, lastSeen: device[1]!, proxy: try savedProxy(serial: serial), runs: runs)
    }

    func attemptedReplies(serial: String) throws -> Set<String> {
        let key = "threads.attemptedReplies." + serial
        if let legacy = UserDefaults.standard.stringArray(forKey: key) {
            try transaction {
                for post in legacy {
                    try execute("INSERT OR IGNORE INTO reply_attempts(serial, post_id, created_at) VALUES(?, ?, ?)",
                                [serial, post, now])
                }
            }
            UserDefaults.standard.removeObject(forKey: key)
        }
        return Set(try rows("SELECT post_id FROM reply_attempts WHERE serial = ?", [serial]).map { $0[0]! })
    }

    func reserveReply(serial: String, postID: String) throws -> Bool {
        var reserved = false
        try transaction {
            try execute("INSERT OR IGNORE INTO reply_attempts(serial, post_id, created_at) VALUES(?, ?, ?)",
                        [serial, postID, now])
            reserved = sqlite3_changes(database) == 1
            try execute("""
                DELETE FROM reply_attempts WHERE serial = ? AND post_id NOT IN
                    (SELECT post_id FROM reply_attempts WHERE serial = ? ORDER BY created_at DESC, rowid DESC LIMIT 300)
                """, [serial, serial])
        }
        return reserved
    }

    func releaseReply(serial: String, postID: String) throws {
        try execute("DELETE FROM reply_attempts WHERE serial = ? AND post_id = ?", [serial, postID])
    }

    private var now: String { ISO8601DateFormatter().string(from: Date()) }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String, _ values: [String?] = []) throws {
        _ = try rows(sql, values)
    }

    private func rows(_ sql: String, _ values: [String?] = []) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let status: Int32
            if let value {
                status = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, transient) }
            } else {
                status = sqlite3_bind_null(statement, Int32(index + 1))
            }
            guard status == SQLITE_OK else { throw failure() }
        }
        var result: [[String?]] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            var row: [String?] = []
            for column in 0..<sqlite3_column_count(statement) {
                row.append(sqlite3_column_text(statement, column).map { String(cString: $0) })
            }
            result.append(row)
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return result
    }

    private func failure() -> StoreError {
        let details = sqlite3_errmsg(database).map { String(cString: $0) } ?? "Không mở được tệp dữ liệu."
        return StoreError(errorDescription: "Không lưu được dữ liệu Phone Farm. " + details)
    }
}
