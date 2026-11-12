import Foundation

/// One URLSession file transfer. Cancellation persists Apple's resume data before returning.
final class ModelFileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64) -> Void
    // The cancellation handler and URLSession delegate run on different executors.
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false

    private var resumeURL: URL { destination.appendingPathExtension("resume") }

    init(destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func configuration(allowCellular: Bool) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = allowCellular
        config.allowsExpensiveNetworkAccess = allowCellular
        config.allowsConstrainedNetworkAccess = false
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        return config
    }

    static func fetch(_ url: URL, to destination: URL, allowCellular: Bool,
                      progress: @escaping @Sendable (Int64) -> Void) async throws {
        let transfer = ModelFileDownload(destination: destination, progress: progress)
        try await transfer.run(url, configuration: configuration(allowCellular: allowCellular))
    }

    func run(_ url: URL, configuration: URLSessionConfiguration) async throws {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let download: URLSessionDownloadTask
                if let data = try? Data(contentsOf: resumeURL) {
                    download = session.downloadTask(withResumeData: data)
                } else {
                    download = session.downloadTask(with: url)
                }
                let shouldCancel = lock.withLock {
                    self.continuation = continuation
                    task = download
                    return cancelled
                }
                if shouldCancel { cancel(download) } else { download.resume() }
            }
        } onCancel: {
            let download = self.lock.withLock {
                self.cancelled = true
                return self.task
            }
            if let download { self.cancel(download) }
        }
    }

    private func cancel(_ download: URLSessionDownloadTask) {
        download.cancel { data in
            self.finish(.failure(CancellationError()), resumeData: data)
        }
    }

    private func finish(_ result: Result<Void, Error>, resumeData: Data? = nil) {
        let continuation = lock.withLock {
            let current = self.continuation
            self.continuation = nil
            return current
        }
        guard let continuation else { return }
        if let resumeData {
            try? resumeData.write(to: resumeURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: resumeURL)
        }
        continuation.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard !lock.withLock({ cancelled }) else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode) else { throw URLError(.badServerResponse) }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, !lock.withLock({ cancelled }) else { return }
        finish(.failure(error), resumeData: (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data)
    }
}
