import AVFoundation
import Foundation
import SQLite3

/// One Voice Memos recording as we care about it: the file on disk plus the
/// metadata Voice Memos keeps in its Core Data store.
struct VoiceMemo {
    let uniqueId: String
    let filename: String
    let url: URL
    let date: Date
    let duration: TimeInterval
    /// User-assigned title. Voice Memos defaults this to an ISO timestamp, so a
    /// label that parses as a date means "never actually named".
    let customLabel: String?
    let folder: String?

    /// `.qta` files come from iOS 26 and carry an embedded transcript; `.m4a`
    /// files (Mac-recorded) do not.
    var isQuickTimeAudio: Bool { url.pathExtension.lowercased() == "qta" }

    var hasDefaultLabel: Bool {
        guard let label = customLabel, !label.isEmpty else { return true }
        return VoiceMemoStore.isoLabelFormatter.date(from: label) != nil
    }
}

/// Reads the Voice Memos library. Everything here is read-only by design.
///
/// `CloudRecordings.db` is Core Data backed by CloudKit; writing to it risks
/// corrupting a synced library, and there is no supported API for renaming a
/// memo. So this store never opens the live database directly — it copies the
/// db plus its `-wal`/`-shm` sidecars to a temp directory and reads the copy.
/// That also sidesteps SQLite's WAL locking against a database Voice Memos may
/// have open.
enum VoiceMemoStore {

    static let isoLabelFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Core Data stores timestamps as seconds since 2001-01-01.
    private static let coreDataEpoch: TimeInterval = 978_307_200

    static var recordingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings")
    }

    /// Reading the library needs Full Disk Access. Distinguish "not granted"
    /// from "no recordings" so the caller can tell the user which it is.
    static func ensureReadable() throws {
        let dir = recordingsURL
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw ToolError("Voice Memos library not found at \(dir.path).")
        }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        } catch {
            throw ToolError(
                "Cannot read the Voice Memos library (\(error.localizedDescription)). " +
                "Grant Full Disk Access to this binary in System Settings > Privacy & Security > Full Disk Access.")
        }
    }

    // MARK: - Metadata

    static func all() throws -> [VoiceMemo] {
        try ensureReadable()
        let dbURL = recordingsURL.appendingPathComponent("CloudRecordings.db")
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw ToolError("CloudRecordings.db not found; is Voice Memos set up on this Mac?")
        }

        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("homeport-vm-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        // The -wal sidecar holds recent writes; copying it too means we see the
        // same state Voice Memos does.
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: dbURL.path + suffix)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            let dst = temp.appendingPathComponent(dbURL.lastPathComponent + suffix)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: src, to: dst)
        }

        let copy = temp.appendingPathComponent(dbURL.lastPathComponent)
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw ToolError("Could not open a copy of CloudRecordings.db.")
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT ZUNIQUEID, ZPATH, ZDATE, ZDURATION, ZCUSTOMLABEL, ZFOLDER
        FROM ZCLOUDRECORDING
        WHERE ZPATH IS NOT NULL
        ORDER BY ZDATE DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ToolError("Could not query CloudRecordings.db: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }

        let folders = folderNames(db)
        var out: [VoiceMemo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let pathC = sqlite3_column_text(stmt, 1) else { continue }
            let filename = String(cString: pathC)
            let url = recordingsURL.appendingPathComponent(filename)
            // Rows can outlive their audio (evicted to iCloud, or pending sync).
            guard FileManager.default.fileExists(atPath: url.path) else { continue }

            let uid = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? filename
            let label = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let folderPK = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 5))

            out.append(VoiceMemo(
                uniqueId: uid,
                filename: filename,
                url: url,
                date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2) + coreDataEpoch),
                duration: sqlite3_column_double(stmt, 3),
                customLabel: label,
                folder: folderPK.flatMap { folders[$0] }
            ))
        }
        return out
    }

    private static func folderNames(_ db: OpaquePointer) -> [Int: String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT Z_PK, ZNAME FROM ZFOLDER", -1, &stmt, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }
        var map: [Int: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1) {
                map[Int(sqlite3_column_int64(stmt, 0))] = String(cString: name)
            }
        }
        return map
    }

    static func find(id: String) throws -> VoiceMemo {
        let all = try all()
        if let hit = all.first(where: { $0.uniqueId == id || $0.filename == id }) { return hit }
        // Allow the extension-less stem, which is what users tend to copy.
        if let hit = all.first(where: { ($0.filename as NSString).deletingPathExtension == id }) { return hit }
        throw ToolError("No recording matches `\(id)`. Use voicememos_list to see ids.")
    }
}
