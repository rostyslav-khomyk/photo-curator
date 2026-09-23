import Foundation

struct GoogleAlbum: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let mediaItemsCount: String?

    var count: Int { Int(mediaItemsCount ?? "0") ?? 0 }
}

struct GoogleAlbumClearResponse: Decodable {
    let removed: Int
}

struct SyncReview: Decodable {
    let token: String
    let destinations: [Destination]
    let fileCount: Int
    let totalBytes: Int64
    let unresolvedFiles: [String]?

    var canReplace: Bool { destinations.contains { $0.managedCount > 0 } }

    enum CodingKeys: String, CodingKey {
        case token, destinations
        case fileCount = "file_count", totalBytes = "total_bytes"
        case unresolvedFiles = "unresolved_files"
    }

    struct Destination: Decodable, Identifiable {
        let id: String
        let title: String
        let isNew: Bool
        let existingCount: Int
        let managedCount: Int
        let selectedCount: Int

        enum CodingKeys: String, CodingKey {
            case id, title
            case isNew = "is_new", existingCount = "existing_count"
            case managedCount = "managed_count", selectedCount = "selected_count"
        }
    }
}

struct TransferProgress: Decodable {
    let runID: String?
    let phase: String
    let message: String
    let completed: Int?
    let total: Int?
    let reused: Int?
    let sentBytes: Int64?
    let totalBytes: Int64?
    let bytesPerSecond: Double?
    let etaSeconds: Double?
    let destinations: [SavedDestination]?

    struct SavedDestination: Decodable {
        let id: String
        let title: String
    }

    var isTransferring: Bool { phase == "uploading" || phase == "processing" }

    var transferSummary: String {
        guard isTransferring else { return "" }
        let sent = ByteCountFormatter.string(fromByteCount: sentBytes ?? 0, countStyle: .file)
        let size = ByteCountFormatter.string(fromByteCount: totalBytes ?? 0, countStyle: .file)
        let speed = ByteCountFormatter.string(fromByteCount: Int64(max(0, bytesPerSecond ?? 0)), countStyle: .file)
        let eta: String
        if let seconds = etaSeconds, seconds.isFinite {
            let minutes = max(1, Int(ceil(seconds / 60)))
            eta = minutes < 60 ? "About \(minutes) min left to send" : "About \(Int(ceil(seconds / 3600))) hr left to send"
        } else {
            eta = phase == "processing" ? "Google is processing" : "Estimating time remaining"
        }
        return "\(sent) of \(size) sent · Avg. \(speed)/s · \(eta)"
    }

    enum CodingKeys: String, CodingKey {
        case phase, message, completed, total, reused, destinations
        case runID = "run_id"
        case sentBytes = "sent_bytes", totalBytes = "total_bytes"
        case bytesPerSecond = "bytes_per_second", etaSeconds = "eta_seconds"
    }
}
