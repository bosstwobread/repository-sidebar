import Foundation

// Read-only decoding of Chromium's IndexedDB LevelDB format and GitHub Desktop's
// local repositories schema. This importer never opens the live database for writing.
enum GitHubDesktopImport {
    static func repositories() throws -> [URL] {
        let profile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GitHub Desktop/IndexedDB", isDirectory: true)
        return try repositories(in: profile)
    }

    static func repositories(in profile: URL) throws -> [URL] {
        let store = profile.appendingPathComponent("file__0.indexeddb.leveldb", isDirectory: true)
        let contents: [String]
        do {
            contents = try FileManager.default.contentsOfDirectory(atPath: profile.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        }
        guard contents.contains(store.lastPathComponent) else {
            if contents.isEmpty { return [] }
            throw DesktopReadError.unsupported
        }

        // Compaction can replace the tables during a read. Retry if the manifest changed
        // or a listed file disappeared while it was being opened.
        for attempt in 0..<3 {
            do {
                let snapshot = try DesktopStore(at: store)
                let repositories = try readRepositories(snapshot)
                if try snapshot.manifestIsCurrent() { return repositories }
            } catch DesktopReadError.changed {
                continue
            } catch let error as CocoaError where attempt < 2
                && (error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile) {
                continue
            }
        }
        throw DesktopReadError.changed
    }

    private static func readRepositories(_ snapshot: DesktopStore) throws -> [URL] {
        // Chromium LevelDB stores numeric identifiers for each database and object store.
        // Resolve both by their schema names before reading any repository object values.
        var metadata: [Data: DesktopEntry] = [:]
        try snapshot.scan { key, entry in
            guard let prefix = try? IndexedDBPrefix(key), prefix.store == 0,
                  prefix.index == 0, !prefix.rest.isEmpty else { return }
            var reader = prefix.rest
            let type = try reader.byte()
            if (prefix.database == 0 && type == 201)
                || (prefix.database > 0 && type == 50 && reader.bytes.last == 0) {
                storeLatest(key, entry, in: &metadata)
            }
        }

        let databaseIDs = Set(try metadata.compactMap { key, entry -> UInt64? in
            guard let value = entry.value else { return nil }
            let prefix = try IndexedDBPrefix(Array(key)[...])
            var reader = prefix.rest
            guard prefix.database == 0, try reader.byte() == 201 else { return nil }
            _ = try reader.indexedDBString() // origin
            guard try reader.indexedDBString() == "Database", reader.isEmpty else { return nil }
            var identifier = ByteCursor(value)
            guard (1...8).contains(identifier.remaining) else { throw DesktopReadError.damaged }
            return try identifier.fixed(identifier.remaining)
        })

        let repositories = try metadata.compactMap { key, entry -> (UInt64, UInt64)? in
            guard let value = entry.value, String(bytes: value, encoding: .utf16BigEndian) == "repositories" else {
                return nil
            }
            let prefix = try IndexedDBPrefix(Array(key)[...])
            var reader = prefix.rest
            guard databaseIDs.contains(prefix.database), try reader.byte() == 50 else { return nil }
            let id = try reader.varint()
            guard try reader.byte() == 0, reader.isEmpty else { return nil }
            return (prefix.database, id)
        }
        guard repositories.count == 1, let (database, objectStore) = repositories.first else {
            // An initialized origin can exist before GitHub Desktop creates its database.
            if databaseIDs.isEmpty { return [] }
            throw DesktopReadError.unsupported
        }

        var records: [Data: DesktopEntry] = [:]
        try snapshot.scan { key, entry in
            guard let prefix = try? IndexedDBPrefix(key), prefix.database == database,
                  prefix.store == objectStore, prefix.index == 1 else { return }
            storeLatest(key, entry, in: &records)
        }

        let urls = try records.values.compactMap { entry -> URL? in
            guard let value = entry.value else { return nil }
            let fields = try RepositoryFields(value)
            let current = URL(fileURLWithPath: fields.path, isDirectory: true).standardizedFileURL
            let files = FileManager.default
            if let main = fields.mainWorktreePath, !files.fileExists(atPath: current.path),
               files.fileExists(atPath: main) {
                return URL(fileURLWithPath: main, isDirectory: true).standardizedFileURL
            }
            return current
        }
        return Array(Set(urls))
    }

    private static func storeLatest(_ key: ArraySlice<UInt8>, _ entry: DesktopEntry,
                                    in records: inout [Data: DesktopEntry]) {
        let key = Data(key)
        if let previous = records[key], previous.sequence >= entry.sequence { return }
        records[key] = entry
    }
}

private enum DesktopReadError: LocalizedError {
    case unsupported
    case damaged
    case changed
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unsupported: return "This version of GitHub Desktop uses an unrecognized repository store."
        case .damaged: return "The local GitHub Desktop repository store couldn’t be read."
        case .changed: return "GitHub Desktop was updating its repository list. Refresh to try again."
        case .tooLarge: return "The local GitHub Desktop repository store is too large to import."
        }
    }
}

private struct DesktopEntry {
    let sequence: UInt64
    let value: ArraySlice<UInt8>?
}

private struct DesktopStore {
    typealias Visit = (ArraySlice<UInt8>, DesktopEntry) throws -> Void
    private static let maximumSnapshotSize = 128 * 1024 * 1024
    private let current: URL
    private let manifest: URL
    private let manifestName: String
    private let manifestData: [UInt8]
    private let tables: [[UInt8]]
    private let logs: [[UInt8]]

    init(at directory: URL) throws {
        current = directory.appendingPathComponent("CURRENT")
        manifestName = String(decoding: try Self.read(current, limit: 256), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard manifestName.hasPrefix("MANIFEST-"), UInt64(manifestName.dropFirst(9)) != nil else {
            throw DesktopReadError.unsupported
        }
        manifest = directory.appendingPathComponent(manifestName)
        manifestData = try Self.read(manifest, limit: Self.maximumSnapshotSize)

        // Replay VersionEdit records to exclude obsolete tables from compactions.
        var liveFiles: Set<UInt64> = []
        var logNumber: UInt64?
        var previousLog: UInt64?
        try Self.readLog(manifestData) { record in
            var reader = ByteCursor(record)
            while !reader.isEmpty {
                switch try reader.varint() {
                case 1:
                    _ = try reader.lengthPrefixed()
                case 2:
                    logNumber = try reader.varint()
                case 3, 4:
                    _ = try reader.varint()
                case 5:
                    _ = try reader.varint()
                    _ = try reader.lengthPrefixed()
                case 6:
                    _ = try reader.varint()
                    liveFiles.remove(try reader.varint())
                case 7:
                    _ = try reader.varint()
                    liveFiles.insert(try reader.varint())
                    _ = try reader.varint()
                    _ = try reader.lengthPrefixed()
                    _ = try reader.lengthPrefixed()
                case 9:
                    previousLog = try reader.varint()
                default:
                    throw DesktopReadError.unsupported
                }
            }
        }
        guard let logNumber else { throw DesktopReadError.damaged }

        let fileNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var remaining = Self.maximumSnapshotSize - manifestData.count
        var tableFiles: [UInt64: String] = [:]
        var logFiles: [UInt64: String] = [:]
        for fileName in fileNames {
            let components = fileName.split(separator: ".")
            guard components.count == 2, let number = UInt64(components[0]) else { continue }
            switch components[1] {
            case "log" where number >= logNumber || number == previousLog:
                logFiles[number] = fileName
            case "ldb" where liveFiles.contains(number):
                tableFiles[number] = fileName
            case "sst" where liveFiles.contains(number) && tableFiles[number] == nil:
                tableFiles[number] = fileName
            default:
                break
            }
        }
        guard liveFiles.isSubset(of: Set(tableFiles.keys)) else { throw DesktopReadError.changed }

        func readFiles(_ names: [UInt64: String]) throws -> [[UInt8]] {
            try names.sorted { $0.key < $1.key }.map { _, name in
                let data = try Self.read(directory.appendingPathComponent(name), limit: remaining)
                remaining -= data.count
                return data
            }
        }
        tables = try readFiles(tableFiles)
        logs = try readFiles(logFiles)
    }

    func manifestIsCurrent() throws -> Bool {
        let name = String(decoding: try Self.read(current, limit: 256), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard name == manifestName else { return false }
        return try Self.read(manifest, limit: Self.maximumSnapshotSize) == manifestData
    }

    private static func read(_ url: URL, limit: Int) throws -> [UInt8] {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var bytes: [UInt8] = []
        while let chunk = try file.read(upToCount: min(limit - bytes.count + 1, 1024 * 1024)),
              !chunk.isEmpty {
            guard chunk.count <= limit - bytes.count else { throw DesktopReadError.tooLarge }
            bytes.append(contentsOf: chunk)
        }
        return bytes
    }

    func scan(_ visit: Visit) throws {
        for table in tables {
            try Self.readTable(table, visit)
        }
        for log in logs {
            try Self.readLog(log) { record in
                var reader = ByteCursor(record)
                let sequence = try reader.fixed(8)
                let count = Int(try reader.fixed(4))
                guard sequence <= (UInt64.max >> 8), count <= reader.remaining / 2 else {
                    throw DesktopReadError.damaged
                }
                for index in 0..<count {
                    let type = try reader.byte()
                    guard type < 2 else { throw DesktopReadError.damaged }
                    let key = try reader.lengthPrefixed()
                    let value = type == 1 ? try reader.lengthPrefixed() : nil
                    try visit(key, DesktopEntry(sequence: sequence + UInt64(index), value: value))
                }
                guard reader.isEmpty else { throw DesktopReadError.damaged }
            }
        }
    }

    private static func readLog(_ bytes: [UInt8], _ visit: (ArraySlice<UInt8>) throws -> Void) throws {
        // The same 32 KiB physical log format is used for the manifest and write-ahead log.
        var offset = 0
        var fragmented: [UInt8]?
        while offset + 7 <= bytes.count {
            let blockEnd = min((offset / 32768 + 1) * 32768, bytes.count)
            if blockEnd - offset < 7 {
                offset = blockEnd
                continue
            }
            var reader = ByteCursor(bytes[offset..<blockEnd])
            let checksum = UInt32(try reader.fixed(4))
            let length = Int(try reader.fixed(2))
            let type = try reader.byte()
            if type == 0, length == 0 {
                offset = blockEnd
                continue
            }
            // A final incomplete record can be observed while Desktop appends to the WAL.
            if length > reader.remaining, blockEnd == bytes.count { break }
            let payload = try reader.take(length)
            guard CRC32C.masked(payload, leading: type) == checksum else { throw DesktopReadError.damaged }
            offset = reader.position
            switch type {
            case 1:
                guard fragmented == nil else { throw DesktopReadError.damaged }
                try visit(payload)
            case 2:
                guard fragmented == nil else { throw DesktopReadError.damaged }
                fragmented = Array(payload)
            case 3, 4:
                guard fragmented != nil else { throw DesktopReadError.damaged }
                fragmented?.append(contentsOf: payload)
                if type == 4, let completed = fragmented {
                    try visit(completed[...])
                    fragmented = nil
                }
            default:
                throw DesktopReadError.damaged
            }
        }
    }

    private static func readTable(_ bytes: [UInt8], _ visit: Visit) throws {
        // The footer points to the metadata and index blocks. Each index entry points
        // to a data block, whose keys end in an internal sequence number and type.
        guard bytes.count >= 48 else { throw DesktopReadError.damaged }
        var magic = ByteCursor(bytes.suffix(8))
        guard try magic.fixed(8) == 0xdb4775248b80fb57 else { throw DesktopReadError.unsupported }
        let footer = bytes.count - 48
        var handles = ByteCursor(bytes[footer..<(footer + 40)])
        _ = try handles.varint()
        _ = try handles.varint()
        let index = try readBlock(bytes, handle: &handles)
        try readBlockEntries(index) { _, value in
            var handle = ByteCursor(value)
            let block = try readBlock(bytes, handle: &handle)
            try readBlockEntries(block) { internalKey, value in
                guard internalKey.count >= 8 else { throw DesktopReadError.damaged }
                var suffix = ByteCursor(internalKey.suffix(8)[...])
                let encoded = try suffix.fixed(8)
                let type = encoded & 255
                guard type < 2 else { throw DesktopReadError.damaged }
                try visit(internalKey.dropLast(8), DesktopEntry(sequence: encoded >> 8,
                                                              value: type == 1 ? value : nil))
            }
        }
    }

    private static func readBlock(_ bytes: [UInt8], handle: inout ByteCursor) throws -> [UInt8] {
        let offset = try handle.length()
        let length = try handle.length()
        guard offset <= bytes.count - 5, length <= bytes.count - 5 - offset else {
            throw DesktopReadError.damaged
        }
        let payload = bytes[offset..<(offset + length)]
        var trailer = ByteCursor(bytes[(offset + length)..<(offset + length + 5)])
        let compression = try trailer.byte()
        guard try trailer.fixed(4) == UInt64(CRC32C.masked(payload, trailing: compression)) else {
            throw DesktopReadError.damaged
        }
        switch compression {
        case 0: return Array(payload)
        case 1: return try Snappy.decode(payload)
        default: throw DesktopReadError.unsupported
        }
    }

    private static func readBlockEntries(_ block: [UInt8],
                                         _ visit: (ArraySlice<UInt8>, ArraySlice<UInt8>) throws -> Void) throws {
        guard block.count >= 4 else { throw DesktopReadError.damaged }
        var trailer = ByteCursor(block.suffix(4))
        let restartCount = Int(try trailer.fixed(4))
        guard restartCount <= (block.count - 4) / 4 else { throw DesktopReadError.damaged }
        var reader = ByteCursor(block.prefix(block.count - (restartCount + 1) * 4))
        var key: [UInt8] = []
        while !reader.isEmpty {
            let shared = try reader.length()
            let inserted = try reader.length()
            let valueLength = try reader.length()
            guard shared <= key.count else { throw DesktopReadError.damaged }
            key.removeLast(key.count - shared)
            key.append(contentsOf: try reader.take(inserted))
            try visit(key[...], reader.take(valueLength))
        }
    }
}

private struct IndexedDBPrefix {
    let database: UInt64
    let store: UInt64
    let index: UInt64
    let rest: ByteCursor

    init(_ key: ArraySlice<UInt8>) throws {
        var reader = ByteCursor(key)
        let sizes = Int(try reader.byte())
        database = try reader.fixed((sizes >> 5) + 1)
        store = try reader.fixed(((sizes >> 2) & 7) + 1)
        index = try reader.fixed((sizes & 3) + 1)
        rest = reader
    }
}

private struct RepositoryFields {
    let path: String
    let mainWorktreePath: String?

    init(_ value: ArraySlice<UInt8>) throws {
        // An IDB sequence is followed by a Blink envelope and a V8 structured clone.
        var reader = ByteCursor(value)
        _ = try reader.varint()
        let compressedHeader = [UInt8(255), 17, 2]
        if reader.bytes[reader.position...].starts(with: compressedHeader) {
            _ = try reader.take(compressedHeader.count)
            reader = ByteCursor(try Snappy.decode(reader.bytes[reader.position...])[...])
        }
        guard try reader.byte() == 255 else { throw DesktopReadError.unsupported }
        let envelope = try reader.varint()
        if envelope >= 21 {
            guard try reader.byte() == 254 else { throw DesktopReadError.unsupported }
            _ = try reader.take(12)
        }
        if envelope >= 16 {
            guard try reader.byte() == 255 else { throw DesktopReadError.unsupported }
            _ = try reader.varint()
        }
        guard try reader.tag() == 111 else { throw DesktopReadError.unsupported } // o = object
        var workingPath: String?
        var mainPath: String?
        var fieldCount: UInt64 = 0
        while true {
            let tag = try reader.tag()
            if tag == 123 { break } // { = end object
            let field = try string(tag, from: &reader)
            if field == "path" || field == "mainWorktreePath" {
                let tag = try reader.tag()
                let text = tag == 48 || tag == 95 ? nil : try string(tag, from: &reader)
                if field == "path" { workingPath = text }
                else { mainPath = text }
            } else {
                try skipValue(&reader, depth: 0)
            }
            fieldCount += 1
        }
        guard try reader.varint() == fieldCount, let workingPath, absolute(workingPath) else {
            throw DesktopReadError.unsupported
        }
        path = workingPath
        mainWorktreePath = mainPath.flatMap { absolute($0) ? $0 : nil }
    }
}

private func absolute(_ path: String) -> Bool {
    path.hasPrefix("/") && !path.contains("\u{0}")
}

private func string(_ tag: UInt8, from reader: inout ByteCursor) throws -> String {
    let encoding: String.Encoding
    switch tag {
    case 34: encoding = .isoLatin1 // " = one-byte string
    case 83: encoding = .utf8      // S = UTF-8 string
    case 99: encoding = .utf16LittleEndian // c = two-byte V8 string on macOS
    default: throw DesktopReadError.unsupported
    }
    guard let value = String(bytes: try reader.lengthPrefixed(), encoding: encoding) else {
        throw DesktopReadError.damaged
    }
    return value
}

private func skipValue(_ reader: inout ByteCursor, depth: Int) throws {
    // Repository rows contain scalar fields and an optional preferences object.
    // Consume structured values so only the top-level path fields can be imported.
    guard depth < 32 else { throw DesktopReadError.unsupported }
    switch try reader.tag() {
    case 34, 83, 99: _ = try reader.lengthPrefixed()
    case 45, 48, 70, 84, 95: break // empty slot, null, booleans, undefined
    case 73, 85, 94: _ = try reader.varint() // signed/unsigned integer or reference
    case 78, 68: _ = try reader.take(8) // double or date
    case 111:
        while try reader.tag() != 123 {
            reader.position -= 1
            try skipValue(&reader, depth: depth + 1)
            try skipValue(&reader, depth: depth + 1)
        }
        _ = try reader.varint()
    default:
        throw DesktopReadError.unsupported
    }
}

private struct ByteCursor {
    let bytes: ArraySlice<UInt8>
    var position: Int
    var remaining: Int { bytes.endIndex - position }
    var isEmpty: Bool { remaining == 0 }

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        self.position = bytes.startIndex
    }

    mutating func take(_ length: Int) throws -> ArraySlice<UInt8> {
        guard length >= 0, length <= remaining else { throw DesktopReadError.damaged }
        let result = bytes[position..<(position + length)]
        position += length
        return result
    }

    mutating func byte() throws -> UInt8 {
        guard position < bytes.endIndex else { throw DesktopReadError.damaged }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func tag() throws -> UInt8 {
        var tag = try byte()
        while tag == 0 { tag = try byte() }
        return tag
    }

    mutating func fixed(_ length: Int) throws -> UInt64 {
        try take(length).enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
    }

    mutating func varint() throws -> UInt64 {
        var output: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            let value = try byte()
            guard shift != 63 || value <= 1 else { throw DesktopReadError.damaged }
            output |= UInt64(value & 127) << shift
            if value < 128 { return output }
        }
        throw DesktopReadError.damaged
    }

    mutating func length() throws -> Int {
        guard let length = Int(exactly: try varint()) else { throw DesktopReadError.tooLarge }
        return length
    }

    mutating func lengthPrefixed() throws -> ArraySlice<UInt8> {
        let size = try length()
        return try take(size)
    }

    mutating func indexedDBString() throws -> String {
        let units = try length()
        guard units <= remaining / 2,
              let text = String(bytes: try take(units * 2), encoding: .utf16BigEndian) else {
            throw DesktopReadError.damaged
        }
        return text
    }
}

private enum CRC32C {
    private static let table: [UInt32] = (0..<256).map { number in
        var remainder = UInt32(number)
        for _ in 0..<8 {
            remainder = remainder & 1 == 0 ? remainder >> 1 : 0x82f63b78 ^ (remainder >> 1)
        }
        return remainder
    }

    static func masked(_ bytes: ArraySlice<UInt8>, leading: UInt8? = nil, trailing: UInt8? = nil) -> UInt32 {
        func next(_ crc: UInt32, _ byte: UInt8) -> UInt32 {
            table[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8)
        }
        var checksum: UInt32 = .max
        if let leading { checksum = next(checksum, leading) }
        for byte in bytes { checksum = next(checksum, byte) }
        if let trailing { checksum = next(checksum, trailing) }
        checksum = ~checksum
        return ((checksum >> 15) | (checksum << 17)) &+ 0xa282ead8
    }
}

private enum Snappy {
    static func decode(_ bytes: ArraySlice<UInt8>) throws -> [UInt8] {
        var reader = ByteCursor(bytes)
        let length = try reader.length()
        guard length <= 16 * 1024 * 1024 else { throw DesktopReadError.tooLarge }
        var output: [UInt8] = []
        output.reserveCapacity(length)
        while !reader.isEmpty {
            let tag = Int(try reader.byte())
            let maximum = length - output.count
            if tag & 3 == 0 {
                let short = tag >> 2
                let count = short < 60 ? short + 1 : Int(try reader.fixed(short - 59)) + 1
                guard count <= maximum else { throw DesktopReadError.damaged }
                output.append(contentsOf: try reader.take(count))
            } else {
                let count: Int
                let offset: Int
                switch tag & 3 {
                case 1:
                    count = 4 + ((tag >> 2) & 7)
                    offset = ((tag & 224) << 3) | Int(try reader.byte())
                case 2:
                    count = (tag >> 2) + 1
                    offset = Int(try reader.fixed(2))
                default:
                    count = (tag >> 2) + 1
                    offset = Int(try reader.fixed(4))
                }
                guard count <= maximum, offset > 0, offset <= output.count else {
                    throw DesktopReadError.damaged
                }
                for _ in 0..<count { output.append(output[output.count - offset]) }
            }
        }
        guard output.count == length else { throw DesktopReadError.damaged }
        return output
    }
}
