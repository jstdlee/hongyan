import Foundation

public protocol StateStore: AnyObject {
    func load() throws -> EngineState
    func save(_ state: EngineState) throws
    func savePlan(_ assetIDs: [String], for id: SnapshotID) throws
    func loadPlan(for id: SnapshotID) throws -> [String]
    func appendUploaded(_ keys: [String], for id: SnapshotID) throws
    func loadUploaded(for id: SnapshotID) throws -> [String]
    func removeSnapshotFiles(for id: SnapshotID) throws
    func loadSyncIndex() throws -> SyncIndex?
    func saveSyncIndex(_ index: SyncIndex) throws
    /// Keys found in the bucket but not in the index at the start of a round.
    func saveRemoteExtras(_ keys: Set<String>, for id: SnapshotID) throws
    func loadRemoteExtras(for id: SnapshotID) throws -> Set<String>
}

/// JSON files in a directory (the App Group container on iOS):
///
///     state.json
///     plan-<id>.json        asset local identifiers, in upload order
///     uploaded-<id>.txt     one finished object key per line
///     sync-index.json       delta sync: object key → asset version
///     extras-<id>.txt       delta sync: keys in the bucket missing from the index
public final class FileStateStore: StateStore {
    public let directory: URL
    private let fm = FileManager.default

    public init(directory: URL) throws {
        self.directory = directory
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var stateURL: URL { directory.appendingPathComponent("state.json") }
    private func planURL(_ id: SnapshotID) -> URL { directory.appendingPathComponent("plan-\(id.rawValue).json") }
    private func uploadedURL(_ id: SnapshotID) -> URL { directory.appendingPathComponent("uploaded-\(id.rawValue).txt") }
    private func extrasURL(_ id: SnapshotID) -> URL { directory.appendingPathComponent("extras-\(id.rawValue).txt") }
    private var syncIndexURL: URL { directory.appendingPathComponent("sync-index.json") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// A missing file means a fresh install. A corrupt file is moved aside and
    /// treated as fresh rather than wedging the backup forever.
    public func load() throws -> EngineState {
        guard fm.fileExists(atPath: stateURL.path) else { return EngineState() }
        let data = try Data(contentsOf: stateURL)
        do {
            return try Self.decoder.decode(EngineState.self, from: data)
        } catch {
            let aside = directory.appendingPathComponent("state.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? fm.moveItem(at: stateURL, to: aside)
            var state = EngineState()
            state.lastError = "State file was unreadable and has been reset"
            return state
        }
    }

    public func save(_ state: EngineState) throws {
        try Self.encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    public func savePlan(_ assetIDs: [String], for id: SnapshotID) throws {
        try Self.encoder.encode(assetIDs).write(to: planURL(id), options: .atomic)
    }

    public func loadPlan(for id: SnapshotID) throws -> [String] {
        try Self.decoder.decode([String].self, from: Data(contentsOf: planURL(id)))
    }

    public func appendUploaded(_ keys: [String], for id: SnapshotID) throws {
        guard !keys.isEmpty else { return }
        let url = uploadedURL(id)
        let data = Data((keys.joined(separator: "\n") + "\n").utf8)
        if fm.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    public func loadUploaded(for id: SnapshotID) throws -> [String] {
        let url = uploadedURL(id)
        guard fm.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    public func removeSnapshotFiles(for id: SnapshotID) throws {
        for url in [planURL(id), uploadedURL(id), extrasURL(id)] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    /// nil when there is no local index yet. A corrupt index counts as none:
    /// the next round rebuilds it from the bucket.
    public func loadSyncIndex() throws -> SyncIndex? {
        guard fm.fileExists(atPath: syncIndexURL.path) else { return nil }
        return try? SyncIndex.decode(Data(contentsOf: syncIndexURL))
    }

    public func saveSyncIndex(_ index: SyncIndex) throws {
        try index.encoded().write(to: syncIndexURL, options: .atomic)
    }

    public func saveRemoteExtras(_ keys: Set<String>, for id: SnapshotID) throws {
        try Data(keys.sorted().joined(separator: "\n").utf8).write(to: extrasURL(id), options: .atomic)
    }

    public func loadRemoteExtras(for id: SnapshotID) throws -> Set<String> {
        guard fm.fileExists(atPath: extrasURL(id).path) else { return [] }
        let text = try String(contentsOf: extrasURL(id), encoding: .utf8)
        return Set(text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
    }
}
