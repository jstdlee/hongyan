import XCTest
@testable import HongyanCore

/// Delta sync: upload only new and changed files into one folder, keep the
/// progress in a local and a remote index, verify it against the bucket, and
/// continue after interruptions.
final class SyncEngineTests: XCTestCase {
    let day: TimeInterval = 86_400
    let s3 = S3Config(endpoint: URL(string: "https://acct.r2.cloudflarestorage.com")!, region: "auto", bucket: "photos", prefix: "phone")
    let creds = S3Credentials(accessKeyID: "AK", secretAccessKey: "SK")
    let layout = KeyLayout(prefix: "phone", timeZone: TimeZone(identifier: "UTC")!)

    var dir: TempDir!
    var library: FakeLibrary!
    var queue: FakeJobQueue!
    var remote: FakeSnapshotStore!
    var store: FileStateStore!
    var clock: FixedClock!
    var settings: BackupSettings!

    override func setUpWithError() throws {
        dir = TempDir()
        library = FakeLibrary()
        queue = FakeJobQueue(jobLimit: 10)
        remote = FakeSnapshotStore(layout: layout)
        store = try FileStateStore(directory: dir.url)
        clock = FixedClock(Date(timeIntervalSince1970: 1_790_000_000))
        settings = BackupSettings(s3: s3, intervalDays: 1, keepLatest: 2) // mode nil = sync
        let config = s3, remote = remote!
        queue.onSucceeded = { url in
            if let key = config.key(fromObjectURL: url) { remote.objects.insert(key) }
        }
    }

    func engine(store customStore: StateStore? = nil) -> BackupEngine {
        BackupEngine(settings: settings, credentials: creds, library: library, queue: queue,
                     remote: remote, store: customStore ?? store, clock: clock,
                     timeZone: TimeZone(identifier: "UTC")!, transport: MockTransport())
    }

    func state() throws -> EngineState { try store.load() }

    @discardableResult
    func syncToCompletion(store customStore: StateStore? = nil, maxPasses: Int = 200) async -> [EngineOutcome] {
        var outcomes: [EngineOutcome] = []
        for _ in 0..<maxPasses {
            let outcome = await engine(store: customStore).run()
            outcomes.append(outcome)
            if outcome != .processing { return outcomes }
            queue.completeAll()
        }
        XCTFail("sync did not settle")
        return outcomes
    }

    /// Start the next round now.
    func nextRound(store customStore: StateStore? = nil) async throws {
        clock.advance(by: 60)
        try engine(store: customStore).requestBackupNow()
        await syncToCompletion(store: customStore)
    }

    var uploadedKeys: [String] { queue.created.compactMap { s3.key(fromObjectURL: $0.destination.url) } }

    // MARK: First sync

    func testDefaultModeIsSync() {
        XCTAssertEqual(BackupSettings().backupMode, .sync)
        XCTAssertEqual(BackupSettings(mode: .snapshot).backupMode, .snapshot)
    }

    func testOldSettingsWithoutModeDecodeAsSync() throws {
        let json = #"{"intervalDays":7,"keepLatest":3,"resources":{"includeVideos":true,"includeLivePhotoVideos":true,"includeEdits":true},"presignSeconds":604800,"maxAttemptsPerFile":4,"maxDeleteBatchesPerRun":20}"#
        let decoded = try JSONDecoder().decode(BackupSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.backupMode, .sync)
        XCTAssertEqual(decoded.scanBudget, 2_000)
        XCTAssertEqual(decoded.checkpointInterval, 500)
    }

    func testFirstSyncUploadsEverythingIntoLibraryFolder() async throws {
        library.addPhoto("a", live: true)
        library.addPhoto("b")
        await syncToCompletion()
        XCTAssertEqual(uploadedKeys.count, 3)
        XCTAssertTrue(uploadedKeys.allSatisfy { $0.hasPrefix("phone/library/") })
        XCTAssertEqual(remote.objects.count, 3)
        // No snapshot folders, no retention in sync mode.
        XCTAssertTrue(remote.manifests.keys.allSatisfy { $0.hasPrefix("phone/.hongyan/rounds/") })
        XCTAssertTrue(remote.deleted.isEmpty)
    }

    func testIndexRecordedLocallyAndInBucket() async throws {
        library.addPhoto("a")
        library.addPhoto("b")
        await syncToCompletion()
        let local = try XCTUnwrap(store.loadSyncIndex())
        XCTAssertEqual(Set(local.entries.keys), remote.objects)
        let remoteIndex = try XCTUnwrap(remote.syncIndexes[layout.syncIndexKey])
        XCTAssertEqual(remoteIndex.entries, local.entries)
        XCTAssertEqual(local.entries.values.map(\.asset).sorted(), ["a", "b"])
    }

    func testRoundRecordAndSummary() async throws {
        library.addPhoto("a")
        await syncToCompletion()
        let summary = try XCTUnwrap(state().lastCompleted)
        XCTAssertEqual(summary.mode, .sync)
        XCTAssertEqual(summary.uploadedFiles, 1)
        XCTAssertEqual(summary.unchangedFiles, 0)
        let record = try XCTUnwrap(remote.manifests[layout.roundRecordKey(summary.id)])
        XCTAssertEqual(record.files.count, 1)
    }

    // MARK: Delta

    func testSecondSyncWithoutChangesUploadsNothing() async throws {
        library.addPhoto("a", live: true)
        library.addPhoto("b")
        await syncToCompletion()
        let before = queue.created.count
        try await nextRound()
        XCTAssertEqual(queue.created.count, before, "nothing changed, nothing uploaded")
        let summary = try XCTUnwrap(state().lastCompleted)
        XCTAssertEqual(summary.uploadedFiles, 0)
        XCTAssertEqual(summary.unchangedFiles, 3)
    }

    func testOnlyNewAndChangedFilesUpload() async throws {
        library.addPhoto("a")
        library.addPhoto("b")
        library.addPhoto("c")
        await syncToCompletion()
        let before = queue.created.count
        library.addPhoto("new")
        library.modify("b", at: clock.now().addingTimeInterval(10))
        try await nextRound()
        let round = queue.created.dropFirst(before).map(\.assetID).sorted()
        XCTAssertEqual(round, ["b", "new"])
        XCTAssertEqual(try state().lastCompleted?.unchangedFiles, 2)
        // The changed file keeps its key (overwritten), so the folder doesn't grow for edits.
        XCTAssertEqual(remote.objects.count, 4)
    }

    func testDeletedPhotoStaysInBucket() async throws {
        library.addPhoto("a")
        library.addPhoto("b")
        await syncToCompletion()
        library.remove("b")
        try await nextRound()
        XCTAssertEqual(remote.objects.count, 2, "sync never deletes backups of photos removed from the phone")
    }

    // MARK: Verify

    func testVerifyFindsMissingRemoteFileAndUploadsItAgain() async throws {
        library.addPhoto("a")
        library.addPhoto("b")
        await syncToCompletion()
        let lost = try XCTUnwrap(remote.objects.sorted().last)
        remote.objects.remove(lost)
        let before = queue.created.count
        try await nextRound()
        XCTAssertEqual(queue.created.count - before, 1)
        XCTAssertTrue(remote.objects.contains(lost))
        XCTAssertEqual(try state().lastCompleted?.missingRemote, 1)
    }

    func testListingFailureDoesNotStartRound() async throws {
        library.addPhoto("a")
        remote.failListKeys = true
        let outcome = await engine().run()
        guard case .failure = outcome else { return XCTFail("expected failure, got \(outcome)") }
        XCTAssertNil(try state().active)
        XCTAssertTrue(queue.created.isEmpty)
        remote.failListKeys = false
        await syncToCompletion()
        XCTAssertEqual(remote.objects.count, 1)
    }

    // MARK: Continue

    func testLostLocalStateContinuesFromRemoteIndex() async throws {
        for i in 0..<4 { library.addPhoto("p\(i)") }
        await syncToCompletion()
        let before = queue.created.count
        let freshDir = TempDir()
        let freshStore = try FileStateStore(directory: freshDir.url) // new install / new phone
        try await nextRound(store: freshStore)
        XCTAssertEqual(queue.created.count, before, "index from the bucket: nothing to upload")
        XCTAssertEqual(try freshStore.loadSyncIndex()?.entries.count, 4)
        XCTAssertEqual(try freshStore.load().lastCompleted?.unchangedFiles, 4)
    }

    func testNoIndexAnywhereAdoptsFilesAlreadyInBucket() async throws {
        for i in 0..<3 { library.addPhoto("p\(i)") }
        await syncToCompletion()
        remote.syncIndexes.removeAll() // e.g. index deleted by hand
        let before = queue.created.count
        let freshDir = TempDir()
        let freshStore = try FileStateStore(directory: freshDir.url)
        try await nextRound(store: freshStore)
        XCTAssertEqual(queue.created.count, before, "files already in the bucket are adopted, not uploaded")
        XCTAssertEqual(try freshStore.load().lastCompleted?.adoptedFiles, 3)
        XCTAssertEqual(remote.syncIndexes[layout.syncIndexKey]?.entries.count, 3, "index rebuilt in the bucket")
    }

    func testInterruptedRoundContinuesWithoutDuplicates() async throws {
        queue.jobLimit = 2
        for i in 0..<7 { library.addPhoto("p\(i)") }
        _ = await engine().run()
        queue.completeAll()
        _ = await engine().run() // second batch created, then the app "dies"
        let restarted = BackupEngine(settings: settings, credentials: creds, library: library, queue: queue,
                                     remote: remote, store: try FileStateStore(directory: dir.url), clock: clock,
                                     timeZone: TimeZone(identifier: "UTC")!, transport: MockTransport())
        queue.completeAll()
        _ = await restarted.run()
        await syncToCompletion()
        XCTAssertEqual(uploadedKeys.count, 7)
        XCTAssertEqual(Set(uploadedKeys).count, 7, "no file uploaded twice")
    }

    func testCheckpointsUploadIndexDuringRound() async throws {
        settings.checkpointEvery = 2
        queue.jobLimit = 2
        for i in 0..<6 { library.addPhoto("p\(i)") }
        _ = await engine().run()
        queue.completeAll()
        _ = await engine().run()
        XCTAssertNotNil(try state().active, "round still running")
        let midRound = try XCTUnwrap(remote.syncIndexes[layout.syncIndexKey])
        XCTAssertEqual(midRound.entries.count, 2, "progress is in the bucket before the round ends")
        await syncToCompletion()
        XCTAssertGreaterThanOrEqual(remote.saveSyncIndexCalls, 3)
    }

    func testScanBudgetSpreadsWalkOverPasses() async throws {
        settings.scanBudgetPerPass = 2
        for i in 0..<5 { library.addPhoto("p\(i)") }
        await syncToCompletion()
        clock.advance(by: 60)
        try engine().requestBackupNow()
        let outcomes = await syncToCompletion()
        XCTAssertGreaterThanOrEqual(outcomes.count, 3, "5 unchanged assets, 2 per pass")
        XCTAssertEqual(try state().lastCompleted?.unchangedFiles, 5)
    }

    func testFailedUploadIsNotRecordedAsSynced() async throws {
        settings.maxAttemptsPerFile = 1
        library.addPhoto("good")
        library.addPhoto("bad")
        for _ in 0..<20 {
            let outcome = await engine().run()
            if outcome != .processing { break }
            queue.completeAll(fail: { $0.assetID == "bad" })
        }
        let index = try XCTUnwrap(store.loadSyncIndex())
        XCTAssertEqual(index.entries.values.map(\.asset), ["good"])
        // Next round tries the failed file again.
        let before = queue.created.count
        try await nextRound()
        XCTAssertEqual(queue.created.dropFirst(before).map(\.assetID), ["bad"])
    }

    func testScheduleStillApplies() async throws {
        library.addPhoto("a")
        await syncToCompletion()
        clock.advance(by: 3600)
        let outcome = await engine().run()
        XCTAssertEqual(outcome, .completed, "not due yet")
        XCTAssertEqual(try state().history.count, 1)
        clock.advance(by: day)
        _ = await engine().run() // nothing changed: the round starts and finishes in one pass
        XCTAssertEqual(try state().history.count, 2, "due after the interval")
    }
}
