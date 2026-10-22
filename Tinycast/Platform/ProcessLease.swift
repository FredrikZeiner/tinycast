import Foundation

@MainActor
final class ProcessLease {
    private let url: URL
    private let owner: String
    private var descriptor: Int32 = -1

    init(url: URL, owner: String) {
        self.url = url
        self.owner = owner
    }

    isolated deinit {
        release()
    }

    var isHeld: Bool { descriptor >= 0 }

    var holder: String {
        let name = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return name.isEmpty ? "Tinycast" : name
    }

    func acquire() -> Bool {
        guard !isHeld else { return true }
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDWR | O_CREAT | O_CLOEXEC, 0o644) } ?? -1
        }
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        descriptor = fd
        ftruncate(fd, 0)
        _ = Array(owner.utf8).withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        return true
    }

    func release() {
        guard isHeld else { return }
        close(descriptor)
        descriptor = -1
    }
}
