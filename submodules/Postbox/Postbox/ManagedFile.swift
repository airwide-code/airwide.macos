import Foundation
#if os(macOS)
    import SwiftSignalKitMac
#else
    import SwiftSignalKit
#endif

public enum ManagedFileMode {
    case read
    case readwrite
    case append
}

private func wrappedWrite(_ fd: Int32, _ data: UnsafeRawPointer, _ count: Int) -> Int {
    return write(fd, data, count)
}

private func wrappedRead(_ fd: Int32, _ data: UnsafeMutableRawPointer, _ count: Int) -> Int {
    return read(fd, data, count)
}

public final class ManagedFile {
    private let queue: Queue
    private let fd: Int32
    private let mode: ManagedFileMode
    
    public init?(queue: Queue, path: String, mode: ManagedFileMode) {
        self.queue = queue
        self.mode = mode
        let fileMode: Int32
        let accessMode: UInt16
        switch mode {
            case .read:
                fileMode = O_RDONLY
                accessMode = S_IRUSR
            case .readwrite:
                fileMode = O_RDWR | O_CREAT
                accessMode = S_IRUSR | S_IWUSR
            case .append:
                fileMode = O_WRONLY | O_CREAT | O_APPEND
                accessMode = S_IRUSR | S_IWUSR
        }
        let fd = open(path, fileMode, accessMode)
        if fd >= 0 {
            self.fd = fd
        } else {
            return nil
        }
    }
    
    deinit {
        assert(self.queue.isCurrent())
        close(self.fd)
    }
    
    public func write(_ data: UnsafeRawPointer, count: Int) -> Int {
        assert(self.queue.isCurrent())
        return wrappedWrite(self.fd, data, count)
    }
    
    public func read(_ data: UnsafeMutableRawPointer, _ count: Int) -> Int {
        assert(self.queue.isCurrent())
        return wrappedRead(self.fd, data, count)
    }
    
    public func seek(position: Int64) {
        lseek(self.fd, position, SEEK_SET)
    }
    
    public func truncate(count: Int64) {
        ftruncate(self.fd, count)
    }
}
