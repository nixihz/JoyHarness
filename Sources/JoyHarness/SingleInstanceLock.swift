import Darwin
import Foundation

final class SingleInstanceLock {
    private let fileDescriptor: Int32

    init?(path: String) {
        let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }

        fileDescriptor = descriptor
        let processID = "\(getpid())\n"
        ftruncate(descriptor, 0)
        _ = processID.withCString { pointer in
            write(descriptor, pointer, strlen(pointer))
        }
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}
