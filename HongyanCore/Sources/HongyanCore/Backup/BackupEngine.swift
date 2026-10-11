import Foundation

public enum EngineOutcome: Equatable, Sendable {
    /// Nothing left to do until the next backup is due.
    case completed
    /// Uploads are in flight or more jobs remain; call again later.
    case processing
    case failure(String)
}

/// One pass of the backup state machine. Called by the upload extension
/// whenever the system wakes it, and by the app (on open, "Back up now",
/// background refresh). Each pass does a bounded amount of work:
///
/// 1. Acknowledge finished upload jobs, recording successes and failures.
/// 2. If no round is active and one is due, start a new one: freeze the
///    list of assets. Delta sync first verifies its index against the bucket.
/// 3. Create upload jobs (presigned PUTs) until the system job limit is full.
///    Delta sync skips files whose version is already in the bucket.
/// 4. When every job is done: full copies upload manifest.json; delta sync
///    uploads its index and a round record.
/// 5. Full copies: delete snapshots beyond "keep latest X".
public final class BackupEngine {
    public let settings: BackupSettings
    public let credentials: S3Credentials?
    let library: PhotoLibrarySource
    let queue: UploadJobQueue
    let remote: SnapshotStore
    let store: StateStore
    let clock: Clock
    let lock: FileLock?
    let layout: KeyLayout
    let presigner: S3Client?
    /// The extension's `BackgroundUploadURLBase`; uploads outside it would be
    /// rejected by the system, so refuse to start.
    let uploadURLBase: URL?

    public init(settings: BackupSettings, credentials: S3Credentials?, library: PhotoLibrarySource,
                queue: UploadJobQueue, remote: SnapshotStore, store: StateStore,
                clock: Clock = SystemClock(), lock: FileLock? = nil, timeZone: TimeZone = .current,
                uploadURLBase: URL? = nil, transport: HTTPTransport = URLSessionTransport()) {
        self.settings = settings
        self.credentials = credentials
        self.library = library
        self.queue = queue
        self.remote = remote
        self.store = store
        self.clock = clock
        self.lock = lock
        self.uploadURLBase = uploadURLBase
        self.layout = KeyLayout(prefix: settings.s3?.normalizedPrefix ?? "", timeZone: timeZone)
        if let s3 = settings.s3, let credentials {
            presigner = S3Client(config: s3, credentials: credentials, transport: transport, clock: clock)
        } else {
            presigner = nil
        }
    }

    /// Ask for a snapshot now, regardless of the schedule.
    public func requestBackupNow() throws {
        var state = try store.load()
        state.forceBackupRequested = true
        try store.save(state)
    }

    /// Mark retention to run on the next pass (e.g. after "keep latest" changed).
    public func requestRetention() throws {
        var state = try store.load()
        state.retentionPending = true
        try store.save(state)
    }

    public func currentState() throws -> EngineState {
        try store.load()
    }

    public func run(shouldStop: () -> Bool = { false }) async -> EngineOutcome {
        if let lock, !lock.tryLock() {
            // Another process is running a pass; ask to be called again.
            return .processing
        }
        defer { lock?.unlock() }

        var state: EngineState
        do {
            state = try store.load()
        } catch {
            return .failure("Cannot read state: \(error)")
        }
        state.lastRunAt = clock.now()

        var problems = settings.validate()
        if credentials?.isComplete != true { problems.append("Access keys are missing") }
        if let base = uploadURLBase, let s3 = settings.s3, !s3.isAllowed(byUploadURLBase: base) {
            problems.append("Endpoint is outside this build's upload URL base (\(base.absoluteString))")
        }
        guard problems.isEmpty, let presigner else {
            state.lastError = problems.joined(separator: "; ")
            try? store.save(state)
            return .completed
        }

        do {
            let outcome = try await pass(&state, presigner: presigner, shouldStop: shouldStop)
            if case .failure = outcome {} else { state.lastError = nil }
            try store.save(state)
            return outcome
        } catch UploadJobQueueError.limitExceeded {
            try? store.save(state)
            return .processing
        } catch {
            state.lastError = String(describing: error)
            try? store.save(state)
            return .failure(String(describing: error))
        }
    }

    // MARK: Pass

    private func pass(_ state: inout EngineState, presigner: S3Client, shouldStop: () -> Bool) async throws -> EngineOutcome {
        try acknowledgeFinishedJobs(&state)

        if state.active == nil {
            let due = settings.schedule.isDue(lastCompletedStart: state.lastCompleted?.startedAt, now: clock.now())
            if due || state.forceBackupRequested {
                try await startRound(&state)
            }
        }

        if state.active != nil {
            try reconcileLostJobs(&state)
            if !shouldStop() {
                try createJobs(&state, presigner: presigner, shouldStop: shouldStop)
            }
            await checkpointIfNeeded(&state)
            if state.active?.isFinished == true {
                if state.active?.isSync == true {
                    try await finishSync(&state)
                } else {
                    try await finishSnapshot(&state)
                }
            }
        }

        if state.active == nil && state.retentionPending && !shouldStop() {
            try await applyRetention(&state)
        }

        if state.active != nil { return .processing }
        return state.retentionPending ? .processing : .completed
    }

    // MARK: 1. Acknowledge

    private func acknowledgeFinishedJobs(_ state: inout EngineState) throws {
        let finished = try queue.finishedJobs()
        guard !finished.isEmpty else { return }
        var uploadedKeys: [String] = []
        var syncedEntries: [String: SyncEntry] = [:]
        let classifier = FailureClassifier(maxAttempts: settings.maxAttemptsPerFile)

        if var active = state.active, let s3 = settings.s3 {
            for job in finished {
                guard let url = job.destination, let key = s3.key(fromObjectURL: url),
                      let flight = active.inFlight.removeValue(forKey: key) else {
                    continue // Not ours, or from an earlier snapshot: just acknowledge.
                }
                switch job.state {
                case .succeeded:
                    uploadedKeys.append(key)
                    active.uploadedCount += 1
                    syncedEntries[key] = SyncEntry(asset: flight.assetID, fingerprint: flight.fingerprint ?? "-",
                                                   uploadedAt: clock.now())
                case .failed, .cancelled:
                    let attempts = flight.attempts + 1
                    switch classifier.decide(errorDomain: job.errorDomain, errorCode: job.errorCode, attempts: attempts) {
                    case .retry:
                        active.retries.append(PendingRetry(key: key, assetID: flight.assetID, resource: flight.resource,
                                                           attempts: attempts, fingerprint: flight.fingerprint))
                    case .giveUp(let reason):
                        active.failed.append(FailedFile(key: key, reason: reason))
                    }
                case .registered, .pending:
                    active.inFlight[key] = flight // Shouldn't be listed as finished; keep tracking.
                }
            }
            try store.appendUploaded(uploadedKeys, for: active.id)
            if active.isSync && !syncedEntries.isEmpty {
                var index = try store.loadSyncIndex() ?? SyncIndex(updatedAt: clock.now())
                index.entries.merge(syncedEntries) { _, new in new }
                index.updatedAt = clock.now()
                try store.saveSyncIndex(index)
            }
            state.active = active
        }
        // Persist before acknowledging: if we die in between, the jobs show up
        // again and are ignored as unknown, which is harmless.
        try store.save(state)
        try queue.acknowledge(jobIDs: finished.map(\.id))
    }

    /// If the system has no jobs at all but we still think some are in flight,
    /// those were lost (e.g. crash between acknowledge and save, or the user
    /// toggled the extension). Queue them again.
    private func reconcileLostJobs(_ state: inout EngineState) throws {
        guard var active = state.active, !active.inFlight.isEmpty else { return }
        // Only when the OS can count jobs; otherwise we can't tell lost from pending.
        guard let processing = try queue.processingJobCount(), processing == 0,
              try queue.finishedJobs().isEmpty else { return }
        for (key, flight) in active.inFlight.sorted(by: { $0.key < $1.key }) {
            active.retries.append(PendingRetry(key: key, assetID: flight.assetID, resource: flight.resource,
                                               attempts: flight.attempts, fingerprint: flight.fingerprint))
        }
        active.inFlight.removeAll()
        state.active = active
    }

    // MARK: 2. Start

    private func startRound(_ state: inout EngineState) async throws {
        let now = clock.now()
        var id = SnapshotID(date: now)
        if let last = state.lastCompleted?.id, id <= last {
            // Two rounds in the same second (or clock went back): stay unique and ordered.
            id = SnapshotID(date: last.date.addingTimeInterval(1))
        }
        let mode = settings.backupMode
        var verification: (missing: Int, extras: Int)?
        if mode == .sync {
            verification = try await verifySyncIndex(roundID: id)
        }
        let assetIDs = try library.allAssetIDs(policy: settings.resources)
        try store.savePlan(assetIDs, for: id)
        var active = ActiveSnapshot(id: id, startedAt: now, totalAssets: assetIDs.count)
        active.mode = mode
        if let verification {
            active.missingRemote = verification.missing
            active.unchangedFiles = 0
            active.adoptedFiles = 0
            active.checkpointedAt = 0
        }
        state.active = active
        state.forceBackupRequested = false
    }

    /// Delta sync, start of a round:
    /// 1. No local index (new install, lost state)? Continue from the index in the bucket.
    /// 2. List `library/`. Index entries whose file is gone are dropped, so
    ///    those files upload again.
    /// 3. Files in the bucket that the index doesn't know are kept as
    ///    "extras": the walk records them without uploading.
    private func verifySyncIndex(roundID: SnapshotID) async throws -> (missing: Int, extras: Int) {
        var index = try store.loadSyncIndex()
        if index?.entries.isEmpty ?? true {
            index = try await remote.loadSyncIndex(key: layout.syncIndexKey)
        }
        var verified = index ?? SyncIndex(updatedAt: clock.now())
        let remoteKeys = try await remote.listKeys(prefix: layout.libraryRoot)
        let missing = verified.entries.keys.filter { !remoteKeys.contains($0) }
        for key in missing { verified.entries[key] = nil }
        let extras = remoteKeys.subtracting(verified.entries.keys)
        verified.updatedAt = clock.now()
        try store.saveSyncIndex(verified)
        try store.saveRemoteExtras(extras, for: roundID)
        return (missing.count, extras.count)
    }

    // MARK: 3. Create jobs

    private func createJobs(_ state: inout EngineState, presigner: S3Client, shouldStop: () -> Bool) throws {
        guard var active = state.active else { return }
        // Without an OS count, assume every job we track is still in flight.
        let processing = try queue.processingJobCount() ?? active.inFlight.count
        let outstanding = processing + (try queue.finishedJobs().count)
        var capacity = queue.jobLimit - outstanding
        guard capacity > 0 else { return }

        var batch: [NewUploadJob] = []
        var batchFlights: [(String, InFlightJob)] = []

        func add(key: String, assetID: String, resource: ResourceInfo, attempts: Int, fingerprint: String?) {
            let destination = presigner.presignedPut(key: key, contentType: ContentType.forFilename(resource.originalFilename),
                                                     expires: settings.presignSeconds)
            batch.append(NewUploadJob(assetID: assetID, resource: resource, destination: destination))
            batchFlights.append((key, InFlightJob(assetID: assetID, resource: resource, attempts: attempts,
                                                  fingerprint: fingerprint)))
            capacity -= 1
        }

        // Delta sync: what the bucket already has.
        let isSync = active.isSync
        var syncEntries = isSync ? (try store.loadSyncIndex()?.entries ?? [:]) : [:]
        let extras = isSync ? try store.loadRemoteExtras(for: active.id) : []
        var adopted = 0, unchanged = 0

        // Retries first.
        var retriesTaken = 0
        for retry in active.retries {
            guard capacity > 0, !shouldStop() else { break }
            retriesTaken += 1
            guard library.asset(id: retry.assetID) != nil else {
                active.failed.append(FailedFile(key: retry.key, reason: "Asset was deleted"))
                continue
            }
            add(key: retry.key, assetID: retry.assetID, resource: retry.resource, attempts: retry.attempts,
                fingerprint: retry.fingerprint)
        }

        // Then walk the plan.
        var cursor = active.cursor
        if capacity > 0 && !active.planExhausted {
            let plan = try store.loadPlan(for: active.id)
            var scanned = 0
            while capacity > 0, cursor.asset < plan.count, !shouldStop(), !isSync || scanned < settings.scanBudget {
                scanned += 1
                let assetID = plan[cursor.asset]
                guard let asset = library.asset(id: assetID) else {
                    active.skippedAssets += 1
                    cursor = PlanCursor(asset: cursor.asset + 1, resource: 0)
                    continue
                }
                let resources = settings.resources.select(library.resources(assetID: assetID))
                let keys = isSync ? layout.libraryKeys(asset: asset, resources: resources)
                                  : layout.objectKeys(snapshot: active.id, asset: asset, resources: resources)
                while capacity > 0, cursor.resource < resources.count {
                    let key = keys[cursor.resource]
                    defer { cursor.resource += 1 }
                    if isSync {
                        if let entry = syncEntries[key], entry.fingerprint == asset.fingerprint {
                            unchanged += 1 // Same version already in the bucket.
                            continue
                        }
                        if syncEntries[key] == nil, extras.contains(key) {
                            // In the bucket from an earlier install: record it, don't upload.
                            syncEntries[key] = SyncEntry(asset: assetID, fingerprint: asset.fingerprint, uploadedAt: clock.now())
                            adopted += 1
                            continue
                        }
                    }
                    add(key: key, assetID: assetID, resource: resources[cursor.resource], attempts: 0,
                        fingerprint: isSync ? asset.fingerprint : nil)
                }
                if cursor.resource >= resources.count {
                    cursor = PlanCursor(asset: cursor.asset + 1, resource: 0)
                }
            }
        }

        if !batch.isEmpty {
            // Atomic: on limitExceeded nothing was created and `state` is left
            // untouched, so the same work is redone on the next pass.
            try queue.create(batch)
        }
        if adopted > 0 {
            var index = try store.loadSyncIndex() ?? SyncIndex(updatedAt: clock.now())
            index.entries = syncEntries
            index.updatedAt = clock.now()
            try store.saveSyncIndex(index)
        }
        if isSync {
            active.unchangedFiles = (active.unchangedFiles ?? 0) + unchanged
            active.adoptedFiles = (active.adoptedFiles ?? 0) + adopted
        }
        active.retries.removeFirst(retriesTaken)
        active.cursor = cursor
        for (key, flight) in batchFlights { active.inFlight[key] = flight }
        state.active = active
    }

    /// Delta sync: upload the index every `checkpointInterval` recorded
    /// files, so the bucket knows the progress if the phone is lost mid-round.
    /// A failed checkpoint is tried again on the next pass.
    private func checkpointIfNeeded(_ state: inout EngineState) async {
        guard var active = state.active, active.isSync else { return }
        let recorded = active.uploadedCount + (active.adoptedFiles ?? 0)
        guard recorded - (active.checkpointedAt ?? 0) >= settings.checkpointInterval else { return }
        do {
            guard let index = try store.loadSyncIndex() else { return }
            try await remote.saveSyncIndex(index, key: layout.syncIndexKey)
            active.checkpointedAt = recorded
            state.active = active
        } catch {
            state.lastError = String(describing: error)
        }
    }

    // MARK: 4. Finish

    private func finishSync(_ state: inout EngineState) async throws {
        guard let active = state.active else { return }
        let uploaded = try store.loadUploaded(for: active.id)
        var seen = Set<String>()
        let files = uploaded.filter { seen.insert($0).inserted }
        let now = clock.now()
        var index = try store.loadSyncIndex() ?? SyncIndex(updatedAt: now)
        index.updatedAt = now
        try store.saveSyncIndex(index)
        try await remote.saveSyncIndex(index, key: layout.syncIndexKey)
        let record = Manifest(snapshotID: active.id, startedAt: active.startedAt, completedAt: now,
                              assetCount: active.totalAssets, skippedAssets: active.skippedAssets,
                              files: files, failed: active.failed)
        try await remote.putManifest(record, key: layout.roundRecordKey(active.id))

        state.record(SnapshotSummary(id: active.id, startedAt: active.startedAt, completedAt: now,
                                     assetCount: active.totalAssets, uploadedFiles: files.count,
                                     failedFiles: active.failed.count, skippedAssets: active.skippedAssets,
                                     mode: .sync, unchangedFiles: active.unchangedFiles,
                                     adoptedFiles: active.adoptedFiles, missingRemote: active.missingRemote))
        state.active = nil
        try store.save(state)
        try? store.removeSnapshotFiles(for: active.id)
    }

    private func finishSnapshot(_ state: inout EngineState) async throws {
        guard let active = state.active else { return }
        let uploaded = try store.loadUploaded(for: active.id)
        var seen = Set<String>()
        let files = uploaded.filter { seen.insert($0).inserted }
        let now = clock.now()
        let manifest = Manifest(snapshotID: active.id, startedAt: active.startedAt, completedAt: now,
                                assetCount: active.totalAssets, skippedAssets: active.skippedAssets,
                                files: files, failed: active.failed)
        try await remote.putManifest(manifest, key: layout.manifestKey(active.id))

        state.record(SnapshotSummary(id: active.id, startedAt: active.startedAt, completedAt: now,
                                     assetCount: active.totalAssets, uploadedFiles: files.count,
                                     failedFiles: active.failed.count, skippedAssets: active.skippedAssets))
        state.active = nil
        state.retentionPending = true
        try store.save(state)
        try? store.removeSnapshotFiles(for: active.id)
    }

    // MARK: 5. Retention

    private func applyRetention(_ state: inout EngineState) async throws {
        let snapshots = try await remote.listSnapshots()
        let doomed = settings.retention.snapshotsToDelete(snapshots, active: state.active?.id)
        var budget = settings.maxDeleteBatchesPerRun
        for id in doomed {
            guard budget > 0 else { return }
            let (done, used) = try await remote.deleteSnapshot(id, maxBatches: budget)
            budget -= used
            if !done { return }
        }
        state.retentionPending = false
    }
}
