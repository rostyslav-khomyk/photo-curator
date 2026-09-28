import Foundation
import Darwin

/// Lock a stable sidecar inode, not the journal inode replaced by atomic saves.
final class PublicationJournalLock {
    private let descriptor: Int32
    init(journal: URL) throws {
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        descriptor = open(journal.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw PublicationFailure.corruptJournal }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw PublicationFailure.conflictingOperation
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
