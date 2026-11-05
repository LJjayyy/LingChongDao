import Darwin
import Foundation
import SQLite3

struct WorkBuddyReadSnapshot: Sendable {
    struct Row: Sendable {
        let unread: Bool
        let status: String
        let updatedAt: Int64?
        let lastActivityAt: Int64?
        fileprivate let owner: String

        fileprivate func completedAfter(_ prompt: Date) -> Bool {
            guard status.lowercased() == "completed", let updatedAt else { return false }
            return Double(updatedAt) > (prompt.timeIntervalSince1970 * 1000).rounded(.down)
        }

        fileprivate func hasSameResultMetadata(as previous: Self) -> Bool {
            status == previous.status && updatedAt == previous.updatedAt &&
                lastActivityAt == previous.lastActivityAt && owner == previous.owner
        }
    }

    fileprivate struct DatabaseIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
    }

    fileprivate let database: DatabaseIdentity
    let rows: [String: Row]
}

struct WorkBuddyReadStateReader: Sendable {
    private enum ReadError: Error {
        case unavailable, invalidDatabase
    }

    let databaseURL: URL

    func read(sessionIDs: Set<String>) throws -> WorkBuddyReadSnapshot {
        let identity = try databaseIdentity()
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(databaseURL.path, &connection, flags, nil) == SQLITE_OK,
              let connection else {
            if let connection { sqlite3_close(connection) }
            throw ReadError.unavailable
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 50)
        guard sqlite3_db_readonly(connection, "main") == 1,
              sqlite3_exec(connection, "PRAGMA query_only = ON; BEGIN", nil, nil, nil) == SQLITE_OK else {
            throw ReadError.invalidDatabase
        }

        let sql = """
            SELECT unread, status, updated_at, last_activity_at, user_id
            FROM sessions
            WHERE id = ? COLLATE BINARY AND transport = 'local' AND deleted_at IS NULL
            LIMIT 2
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw ReadError.invalidDatabase }
        defer { sqlite3_finalize(statement) }

        var rows: [String: WorkBuddyReadSnapshot.Row] = [:]
        for id in sessionIDs where id.utf8.count == 36 && UUID(uuidString: id) != nil {
            // The ID remains bound until this synchronous query and reset return.
            let row = try id.withCString { idBytes -> WorkBuddyReadSnapshot.Row? in
                defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
                guard sqlite3_bind_text(statement, 1, idBytes, -1, nil) == SQLITE_OK else {
                    throw ReadError.invalidDatabase
                }
                switch sqlite3_step(statement) {
                case SQLITE_DONE: return nil
                case SQLITE_ROW:
                    let row = readRow(statement)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw ReadError.invalidDatabase }
                    return row
                default: throw ReadError.unavailable
                }
            }
            rows[id] = row
        }
        guard try databaseIdentity() == identity else { throw ReadError.unavailable }
        return WorkBuddyReadSnapshot(database: identity, rows: rows)
    }

    private func databaseIdentity() throws -> WorkBuddyReadSnapshot.DatabaseIdentity {
        var info = stat()
        guard databaseURL.isFileURL, lstat(databaseURL.path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid() else {
            throw ReadError.unavailable
        }
        return .init(device: info.st_dev, inode: info.st_ino)
    }

    private func readRow(_ statement: OpaquePointer) -> WorkBuddyReadSnapshot.Row? {
        guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
              let status = text(statement, 1), !status.isEmpty,
              let owner = text(statement, 4),
              [2, 3].allSatisfy({
                  let type = sqlite3_column_type(statement, Int32($0))
                  return type == SQLITE_INTEGER || type == SQLITE_NULL
              }) else { return nil }
        let unread = sqlite3_column_int64(statement, 0)
        guard unread == 0 || unread == 1 else { return nil }
        let updatedAt = integer(statement, 2)
        let lastActivityAt = integer(statement, 3)
        guard updatedAt != nil || lastActivityAt != nil else { return nil }
        return .init(unread: unread == 1, status: status, updatedAt: updatedAt,
                     lastActivityAt: lastActivityAt, owner: owner)
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let value = sqlite3_column_text(statement, column) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, column))
        guard length <= 1024 else { return nil }
        return String(bytes: UnsafeBufferPointer(start: value, count: length), encoding: .utf8)
    }

    private func integer(_ statement: OpaquePointer, _ column: Int32) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_INTEGER ? sqlite3_column_int64(statement, column) : nil
    }
}

struct WorkBuddyReadTracker {
    private var database: WorkBuddyReadSnapshot.DatabaseIdentity?
    private var unread: [WorkBuddyReminder: WorkBuddyReadSnapshot.Row] = [:]

    mutating func ingest(_ snapshot: WorkBuddyReadSnapshot, reminders: [WorkBuddyReminder]) -> [WorkBuddyReminder] {
        if database != snapshot.database {
            reset()
            database = snapshot.database
        }
        let grouped = Dictionary(grouping: reminders, by: \.sessionID)
        var nextUnread: [WorkBuddyReminder: WorkBuddyReadSnapshot.Row] = [:]
        var read: [WorkBuddyReminder] = []
        for reminder in reminders where grouped[reminder.sessionID]?.count == 1 {
            guard let row = snapshot.rows[reminder.sessionID], row.completedAfter(reminder.promptReceivedAt) else { continue }
            if row.unread {
                nextUnread[reminder] = row
            } else if let previous = unread[reminder], row.hasSameResultMetadata(as: previous) {
                read.append(reminder)
            }
        }
        unread = nextUnread
        return read
    }

    mutating func reset() {
        database = nil
        unread.removeAll()
    }
}
