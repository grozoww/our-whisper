import Foundation

/// The seam between the app and the network.
///
/// `CONTRIBUTING.md` requires that nothing in the build, the tests or CI needs an API key, and
/// that cloud providers are tested against recorded fixtures. That is only possible if the thing
/// making the request can be swapped, so every provider takes one of these rather than reaching
/// for `URLSession.shared` directly.
protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Writes a large body straight to disk, reporting the bytes written so far.
    ///
    /// Separate from `send` because the callers fetch a 12 MB disk image and a 2.8 GB model:
    /// holding either in memory to show a progress bar would be the wrong trade twice over.
    /// Declared here rather than only in an extension so `URLSessionHTTPClient`'s version is the
    /// one that runs when the call goes through `any HTTPClient` — an extension-only method is
    /// chosen at compile time and the default below would win.
    ///
    /// Bytes and not a fraction, because the caller knows the total and this does not: GitHub
    /// serves the image from a redirect, and a response without a `Content-Length` would leave a
    /// fraction pinned at zero for the whole download and then jump to one. The release's own
    /// `assets[].size` is the honest denominator.
    func download(
        _ request: URLRequest,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> HTTPURLResponse
}

extension HTTPClient {
    /// Enough for anything answering from memory, which is what the tests do. Adding the
    /// requirement above without this would have meant editing `StubHTTPClient` and every
    /// recorded-response test for a method they do not use.
    func download(
        _ request: URLRequest,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> HTTPURLResponse {
        let (data, response) = try await send(request)
        try data.write(to: destination, options: .atomic)
        progress(Int64(data.count))
        return response
    }
}

struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.notHTTP
        }
        return (data, http)
    }

    /// Lets URLSession write the file itself, and reads the progress off the task.
    ///
    /// This used to stream `bytes(for:)` into the file a byte at a time. That was fine for a 12 MB
    /// disk image and not for the 2.8 GB cleanup model: measured in a debug build, the app took
    /// 319 s for a file curl fetches in about 65, and the same loop given a byte range timed out
    /// on Hugging Face's CDN altogether. A download task writes at the speed of the network.
    ///
    /// Progress is polled rather than delegated. The async `download(for:delegate:)` delivers no
    /// `didWriteData` callbacks at all on a shared, default or ephemeral session, which left the
    /// progress bar at zero for the whole download — but the task's own byte count is always
    /// right, and a quarter of a second is as often as a progress bar needs it.
    func download(
        _ request: URLRequest,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> HTTPURLResponse {
        let handle = DownloadHandle()
        let poller = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if let received = handle.bytesReceived { progress(received) }
            }
        }
        defer { poller.cancel() }

        let response: HTTPURLResponse = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: request) { location, response, error in
                    // The file at `location` is deleted when this returns, so it is moved here,
                    // on URLSession's queue, rather than after the continuation resumes.
                    if let error { return continuation.resume(throwing: error) }
                    guard let location, let http = response as? HTTPURLResponse else {
                        return continuation.resume(throwing: HTTPError.notHTTP)
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        return continuation.resume(throwing: HTTPError.from(status: http.statusCode, body: Data()))
                    }
                    do {
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: location, to: destination)
                        continuation.resume(returning: http)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                handle.start(task)
            }
        } onCancel: {
            handle.cancel()
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path(percentEncoded: false))
        progress((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        return response
    }
}

/// The task behind one download, shared between the code that starts it, the progress poller
/// and a cancellation that can arrive before the task exists.
private final class DownloadHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var isCancelled = false

    var bytesReceived: Int64? {
        lock.withLock { task?.countOfBytesReceived }
    }

    func start(_ task: URLSessionDownloadTask) {
        let cancelled = lock.withLock {
            self.task = task
            return isCancelled
        }
        cancelled ? task.cancel() : task.resume()
    }

    func cancel() {
        let task = lock.withLock {
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }
}

enum HTTPError: LocalizedError {
    case notHTTP
    case unauthorized
    case rateLimited
    case status(Int, String?)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .notHTTP:
            "The server sent a response that was not HTTP."
        case .unauthorized:
            "The API key was rejected. Check it in Configuration."
        case .rateLimited:
            "The provider is rate-limiting this key. Try again shortly."
        case .status(let code, let detail):
            detail.map { "The provider returned \(code): \($0)" } ?? "The provider returned \(code)."
        case .malformedResponse(let detail):
            "Could not read the provider's response: \(detail)"
        }
    }

    /// Maps a status code to the error the user should see. 401 and 429 get their own cases
    /// because they are the two the user can actually do something about.
    static func from(status: Int, body: Data) -> HTTPError {
        switch status {
        case 401, 403: .unauthorized
        case 429: .rateLimited
        default: .status(status, message(in: body))
        }
    }

    /// Providers put their human-readable reason in different places. Pulling out whichever is
    /// present beats showing the user a raw JSON blob.
    private static func message(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        for key in ["error_message", "message", "error", "detail"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}
