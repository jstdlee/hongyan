import Foundation
import Photos
import ShoeboxCore

/// Uploads by the app itself, used while Shoebox keeps itself awake.
///
/// It plays the role of PhotoKit's background upload jobs: the engine creates
/// jobs (presigned PUTs), this queue exports each resource to a temporary
/// file and sends it, then reports the result as a finished job. The object
/// keys are the same as with the extension, so an upload done twice (once by
/// each path) only overwrites the same object.
///
/// Jobs live in memory. If the app stops, the engine finds the in-flight
/// files with no job and queues them again.
final class DirectUploadQueue: UploadJobQueue, @unchecked Sendable {
    private struct Job {
        var url: URL
        var state: UploadJobState
        var errorDomain: String?
        var errorCode: Int?
    }

    let jobLimit: Int
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private let session: URLSession

    init(concurrentUploads: Int = 4) {
        jobLimit = concurrentUploads
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 6 * 3600
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
    }

    func finishedJobs() throws -> [UploadJobInfo] {
        lock.lock(); defer { lock.unlock() }
        return jobs.compactMap { id, job in
            guard job.state == .succeeded || job.state == .failed else { return nil }
            return UploadJobInfo(id: id, destination: job.url, state: job.state,
                                 errorDomain: job.errorDomain, errorCode: job.errorCode)
        }
    }

    func processingJobCount() throws -> Int? {
        lock.lock(); defer { lock.unlock() }
        return jobs.values.filter { $0.state == .pending || $0.state == .registered }.count
    }

    func acknowledge(jobIDs: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        for id in jobIDs { jobs[id] = nil }
    }

    func create(_ newJobs: [NewUploadJob]) throws {
        lock.lock()
        guard jobs.count + newJobs.count <= jobLimit else {
            lock.unlock()
            throw UploadJobQueueError.limitExceeded
        }
        var started: [(String, NewUploadJob)] = []
        for job in newJobs {
            let id = UUID().uuidString
            jobs[id] = Job(url: job.destination.url, state: .pending)
            started.append((id, job))
        }
        lock.unlock()
        for (id, job) in started {
            Task.detached(priority: .utility) { [self] in await self.upload(id: id, job: job) }
        }
    }

    private func upload(id: String, job: NewUploadJob) async {
        guard let resource = PhotoKitLibrarySource().phResource(assetID: job.assetID, index: job.resource.index) else {
            // The photo was deleted: a permanent error, the engine gives up on it.
            finish(id, .failed, domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)
            return
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(id)")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true // download from iCloud when needed
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options)
            let (_, response) = try await session.upload(for: job.destination.urlRequest, fromFile: file)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                finish(id, .succeeded)
            } else {
                finish(id, .failed, domain: "HTTP", code: status)
            }
        } catch {
            let error = error as NSError
            finish(id, .failed, domain: error.domain, code: error.code)
        }
    }

    private func finish(_ id: String, _ state: UploadJobState, domain: String? = nil, code: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard var job = jobs[id] else { return }
        job.state = state
        job.errorDomain = domain
        job.errorCode = code
        jobs[id] = job
    }
}
