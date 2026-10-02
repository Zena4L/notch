import Foundation

/// URLSession plumbing for plain file downloads (PDFs, archives, installers… anything that
/// isn't a video page for yt-dlp). Each job starts as a data task so we can look at the
/// server's answer first, then turns into a download task. All callbacks arrive on the main queue.
nonisolated final class DirectDownloader: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Handlers {
        /// Return false to stop before any data is written (wrong file type, error page…).
        var response: @MainActor (UUID, URLResponse) -> Bool
        var progress: @MainActor (UUID, _ written: Int64, _ expected: Int64?) -> Void
        /// Move the file out of `location` before returning; URLSession deletes it afterwards.
        var finished: @MainActor (UUID, _ location: URL) -> Void
        var failed: @MainActor (UUID, Error?) -> Void
    }

    var handlers: Handlers?

    // Only touched on the main queue (the session's delegate queue, and our callers).
    private var session: URLSession!
    private var ids: [Int: UUID] = [:]
    private var tasks: [UUID: URLSessionTask] = [:]
    private var completed: Set<UUID> = []

    init(configuration: URLSessionConfiguration = .default) {
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }

    func start(_ id: UUID, request: URLRequest) {
        let task = session.dataTask(with: request)
        ids[task.taskIdentifier] = id
        tasks[id] = task
        task.resume()
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
    }

    func isRunning(_ id: UUID) -> Bool { tasks[id] != nil }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let id = ids[dataTask.taskIdentifier] else { return completionHandler(.cancel) }
        let ok = MainActor.assumeIsolated { handlers?.response(id, response) ?? false }
        completionHandler(ok ? .becomeDownload : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didBecome downloadTask: URLSessionDownloadTask) {
        guard let id = ids[dataTask.taskIdentifier] else { return }
        ids[downloadTask.taskIdentifier] = id
        tasks[id] = downloadTask
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let id = ids[downloadTask.taskIdentifier] else { return }
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        MainActor.assumeIsolated { handlers?.progress(id, totalBytesWritten, expected) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = ids[downloadTask.taskIdentifier] else { return }
        completed.insert(id)
        MainActor.assumeIsolated { handlers?.finished(id, location) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = ids.removeValue(forKey: task.taskIdentifier) else { return }
        // A data task that became a download completes too; wait for the download task.
        if task is URLSessionDataTask, tasks[id] !== task { return }
        tasks[id] = nil
        ids = ids.filter { $0.value != id }
        if completed.remove(id) == nil {
            MainActor.assumeIsolated { handlers?.failed(id, error) }
        }
    }
}
