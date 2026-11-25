import Foundation
import WatchConnectivity

final class PairLink: NSObject, WCSessionDelegate {
    @MainActor var receive: ((Data) -> Void)?
    @MainActor var ready: (() -> Void)?
    private let session: WCSession? = WCSession.isSupported() ? .default : nil
    @MainActor private var newestFile: URL?
    @MainActor private var failedAttempts = 0
    private let fileKey = "ArcWatchSnapshot"
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("outbox", isDirectory: true)

    func activate() {
        session?.delegate = self
        session?.activate()
    }

    @MainActor func send(_ data: Data) throws {
        guard let session, session.activationState == .activated else { return }
        #if os(iOS)
        guard session.isPaired && session.isWatchAppInstalled else { return }
        #endif
        var currentFile: URL?
        if data.count < 55_000 {
            try session.updateApplicationContext(["snapshot": data])
            if session.isReachable { session.sendMessageData(data, replyHandler: nil) { _ in } }
        } else {
            // Application context has a size limit. Files also reach a sleeping counterpart.
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(UUID().uuidString)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            currentFile = url
            session.transferFile(url, metadata: [fileKey: true])
        }
        // A newer full snapshot supersedes files still waiting to begin transmission.
        newestFile = currentFile
        for old in session.outstandingFileTransfers where old.file.metadata?[fileKey] as? Bool == true
            && old.file.fileURL != currentFile && !old.isTransferring {
            old.cancel()
        }
    }

    private func deliver(_ data: Data?) {
        guard let data else { return }
        Task { @MainActor [weak self] in self?.receive?(data) }
    }
    private func refresh() { Task { @MainActor [weak self] in self?.ready?() } }
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        guard state == .activated else { return }
        deliver(session.receivedApplicationContext["snapshot"] as? Data)
        refresh()
    }
    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) { deliver(context["snapshot"] as? Data) }
    func session(_ session: WCSession, didReceiveMessageData messageData: Data) { deliver(messageData) }
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        if file.metadata?[fileKey] as? Bool == true { deliver(try? Data(contentsOf: file.fileURL)) }
    }
    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard fileTransfer.file.metadata?[fileKey] as? Bool == true else { return }
        let url = fileTransfer.file.fileURL
        try? FileManager.default.removeItem(at: url)
        Task { @MainActor [weak self] in
            guard let self, self.newestFile == url else { return }
            guard error != nil else { self.failedAttempts = 0; return }
            guard self.failedAttempts < 3 else { return }
            self.failedAttempts += 1
            try? await Task.sleep(for: .seconds(5 * self.failedAttempts))
            if self.newestFile == url { self.ready?() }
        }
    }
    func sessionReachabilityDidChange(_ session: WCSession) { if session.isReachable { refresh() } }
    #if os(iOS)
    func sessionWatchStateDidChange(_ session: WCSession) { refresh() }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}
