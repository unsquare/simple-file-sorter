import Foundation
import SQLite3

struct PeopleRecognitionSnapshot {
    var trackedPeople: [String]
    var learnedFaceHashesByName: [String: Set<UInt64>]
    var rejectedFaceHashesByName: [String: Set<UInt64>]
    var learnedFileHashesByName: [String: Set<String>]
    var rejectedFileHashesByName: [String: Set<String>]

    static let empty = PeopleRecognitionSnapshot(
        trackedPeople: [],
        learnedFaceHashesByName: [:],
        rejectedFaceHashesByName: [:],
        learnedFileHashesByName: [:],
        rejectedFileHashesByName: [:]
    )

    var isEmpty: Bool {
        trackedPeople.isEmpty &&
        learnedFaceHashesByName.values.allSatisfy(\.isEmpty) &&
        rejectedFaceHashesByName.values.allSatisfy(\.isEmpty) &&
        learnedFileHashesByName.values.allSatisfy(\.isEmpty) &&
        rejectedFileHashesByName.values.allSatisfy(\.isEmpty)
    }
}

final class PeopleRecognitionStore {
    private enum HashKind: Int32 {
        case rejected = 0
        case learned = 1
    }

    private let databaseURL: URL

    init(directoryURL: URL) {
        self.databaseURL = directoryURL.appendingPathComponent("people-recognition.sqlite", isDirectory: false)
    }

    func loadSnapshot() throws -> PeopleRecognitionSnapshot {
        try withDatabase { db in
            var trackedPeople: [String] = []
            var learnedFaceHashesByName: [String: Set<UInt64>] = [:]
            var rejectedFaceHashesByName: [String: Set<UInt64>] = [:]
            var learnedFileHashesByName: [String: Set<String>] = [:]
            var rejectedFileHashesByName: [String: Set<String>] = [:]

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            let peopleSQL = "SELECT name FROM people ORDER BY name COLLATE NOCASE ASC;"
            guard sqlite3_prepare_v2(db, peopleSQL, -1, &statement, nil) == SQLITE_OK else {
                throw databaseError(db, fallbackMessage: "Failed to read people list")
            }

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let cString = sqlite3_column_text(statement, 0) else { continue }
                trackedPeople.append(String(cString: cString))
            }

            sqlite3_finalize(statement)
            statement = nil

            let faceSQL = "SELECT person_name, hash, kind FROM person_face_hashes;"
            guard sqlite3_prepare_v2(db, faceSQL, -1, &statement, nil) == SQLITE_OK else {
                throw databaseError(db, fallbackMessage: "Failed to read face hashes")
            }

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let nameCString = sqlite3_column_text(statement, 0) else { continue }
                let name = String(cString: nameCString)
                let rawHash = sqlite3_column_int64(statement, 1)
                guard rawHash >= 0 else { continue }
                let hash = UInt64(rawHash)
                let kind = sqlite3_column_int(statement, 2)

                if kind == HashKind.learned.rawValue {
                    learnedFaceHashesByName[name, default: []].insert(hash)
                } else {
                    rejectedFaceHashesByName[name, default: []].insert(hash)
                }
            }

            sqlite3_finalize(statement)
            statement = nil

            let fileSQL = "SELECT person_name, hash, kind FROM person_file_hashes;"
            guard sqlite3_prepare_v2(db, fileSQL, -1, &statement, nil) == SQLITE_OK else {
                throw databaseError(db, fallbackMessage: "Failed to read file hashes")
            }

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let nameCString = sqlite3_column_text(statement, 0),
                      let hashCString = sqlite3_column_text(statement, 1)
                else { continue }

                let name = String(cString: nameCString)
                let hash = String(cString: hashCString)
                let kind = sqlite3_column_int(statement, 2)

                if kind == HashKind.learned.rawValue {
                    learnedFileHashesByName[name, default: []].insert(hash)
                } else {
                    rejectedFileHashesByName[name, default: []].insert(hash)
                }
            }

            return PeopleRecognitionSnapshot(
                trackedPeople: trackedPeople,
                learnedFaceHashesByName: learnedFaceHashesByName,
                rejectedFaceHashesByName: rejectedFaceHashesByName,
                learnedFileHashesByName: learnedFileHashesByName,
                rejectedFileHashesByName: rejectedFileHashesByName
            )
        }
    }

    func saveSnapshot(_ snapshot: PeopleRecognitionSnapshot) throws {
        try withDatabase { db in
            try execute(db, sql: "BEGIN IMMEDIATE TRANSACTION;")
            do {
                try execute(db, sql: "DELETE FROM person_face_hashes;")
                try execute(db, sql: "DELETE FROM person_file_hashes;")
                try execute(db, sql: "DELETE FROM people;")

                var insertPersonStatement: OpaquePointer?
                var insertFaceStatement: OpaquePointer?
                var insertFileStatement: OpaquePointer?

                defer {
                    sqlite3_finalize(insertPersonStatement)
                    sqlite3_finalize(insertFaceStatement)
                    sqlite3_finalize(insertFileStatement)
                }

                let insertPersonSQL = "INSERT INTO people(name) VALUES(?);"
                guard sqlite3_prepare_v2(db, insertPersonSQL, -1, &insertPersonStatement, nil) == SQLITE_OK else {
                    throw databaseError(db, fallbackMessage: "Failed to prepare person insert")
                }

                let insertFaceSQL = "INSERT INTO person_face_hashes(person_name, hash, kind) VALUES(?, ?, ?);"
                guard sqlite3_prepare_v2(db, insertFaceSQL, -1, &insertFaceStatement, nil) == SQLITE_OK else {
                    throw databaseError(db, fallbackMessage: "Failed to prepare face hash insert")
                }

                let insertFileSQL = "INSERT INTO person_file_hashes(person_name, hash, kind) VALUES(?, ?, ?);"
                guard sqlite3_prepare_v2(db, insertFileSQL, -1, &insertFileStatement, nil) == SQLITE_OK else {
                    throw databaseError(db, fallbackMessage: "Failed to prepare file hash insert")
                }

                let sortedPeople = snapshot.trackedPeople.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                for person in sortedPeople {
                    try bindAndStep(db: db, statement: insertPersonStatement, text1: person)
                }

                for person in sortedPeople {
                    let learnedFaces = Array(snapshot.learnedFaceHashesByName[person] ?? []).sorted()
                    for hash in learnedFaces {
                        try bindAndStep(db: db, statement: insertFaceStatement, text1: person, int641: Int64(bitPattern: hash), int321: HashKind.learned.rawValue)
                    }

                    let rejectedFaces = Array(snapshot.rejectedFaceHashesByName[person] ?? []).sorted()
                    for hash in rejectedFaces {
                        try bindAndStep(db: db, statement: insertFaceStatement, text1: person, int641: Int64(bitPattern: hash), int321: HashKind.rejected.rawValue)
                    }

                    let learnedFiles = Array(snapshot.learnedFileHashesByName[person] ?? []).sorted()
                    for hash in learnedFiles {
                        try bindAndStep(db: db, statement: insertFileStatement, text1: person, text2: hash, int321: HashKind.learned.rawValue)
                    }

                    let rejectedFiles = Array(snapshot.rejectedFileHashesByName[person] ?? []).sorted()
                    for hash in rejectedFiles {
                        try bindAndStep(db: db, statement: insertFileStatement, text1: person, text2: hash, int321: HashKind.rejected.rawValue)
                    }
                }

                try execute(db, sql: "COMMIT;")
            } catch {
                _ = try? execute(db, sql: "ROLLBACK;")
                throw error
            }
        }
    }

    private func withDatabase<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else {
            defer { sqlite3_close(db) }
            throw NSError(domain: "PeopleRecognitionStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unable to open people recognition database"
            ])
        }

        defer { sqlite3_close(db) }

        try execute(db, sql: "PRAGMA foreign_keys = ON;")
        try createSchemaIfNeeded(db)
        return try operation(db)
    }

    private func createSchemaIfNeeded(_ db: OpaquePointer) throws {
        try execute(db, sql: """
        CREATE TABLE IF NOT EXISTS people (
            name TEXT PRIMARY KEY COLLATE NOCASE
        );
        """)

        try execute(db, sql: """
        CREATE TABLE IF NOT EXISTS person_face_hashes (
            person_name TEXT NOT NULL,
            hash INTEGER NOT NULL,
            kind INTEGER NOT NULL,
            PRIMARY KEY (person_name, hash, kind),
            FOREIGN KEY (person_name) REFERENCES people(name) ON DELETE CASCADE
        );
        """)

        try execute(db, sql: """
        CREATE TABLE IF NOT EXISTS person_file_hashes (
            person_name TEXT NOT NULL,
            hash TEXT NOT NULL,
            kind INTEGER NOT NULL,
            PRIMARY KEY (person_name, hash, kind),
            FOREIGN KEY (person_name) REFERENCES people(name) ON DELETE CASCADE
        );
        """)
    }

    private func execute(_ db: OpaquePointer, sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw databaseError(db, fallbackMessage: "SQLite execution failed")
        }
    }

    private func bindAndStep(db: OpaquePointer, statement: OpaquePointer?, text1: String) throws {
        guard let statement else {
            throw databaseError(db, fallbackMessage: "SQLite statement unavailable")
        }

        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)

        guard sqlite3_bind_text(statement, 1, text1, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
            throw databaseError(db, fallbackMessage: "Failed to bind text parameter")
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(db, fallbackMessage: "SQLite insert step failed")
        }
    }

    private func bindAndStep(db: OpaquePointer, statement: OpaquePointer?, text1: String, int641: Int64, int321: Int32) throws {
        guard let statement else {
            throw databaseError(db, fallbackMessage: "SQLite statement unavailable")
        }

        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)

        guard sqlite3_bind_text(statement, 1, text1, -1, SQLITE_TRANSIENT) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, int641) == SQLITE_OK,
              sqlite3_bind_int(statement, 3, int321) == SQLITE_OK
        else {
            throw databaseError(db, fallbackMessage: "Failed to bind parameters")
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(db, fallbackMessage: "SQLite insert step failed")
        }
    }

    private func bindAndStep(db: OpaquePointer, statement: OpaquePointer?, text1: String, text2: String, int321: Int32) throws {
        guard let statement else {
            throw databaseError(db, fallbackMessage: "SQLite statement unavailable")
        }

        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)

        guard sqlite3_bind_text(statement, 1, text1, -1, SQLITE_TRANSIENT) == SQLITE_OK,
              sqlite3_bind_text(statement, 2, text2, -1, SQLITE_TRANSIENT) == SQLITE_OK,
              sqlite3_bind_int(statement, 3, int321) == SQLITE_OK
        else {
            throw databaseError(db, fallbackMessage: "Failed to bind parameters")
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(db, fallbackMessage: "SQLite insert step failed")
        }
    }

    private func databaseError(_ db: OpaquePointer, fallbackMessage: String) -> NSError {
        let message = String(cString: sqlite3_errmsg(db))
        return NSError(domain: "PeopleRecognitionStore", code: 2, userInfo: [
            NSLocalizedDescriptionKey: message.isEmpty ? fallbackMessage : message
        ])
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
