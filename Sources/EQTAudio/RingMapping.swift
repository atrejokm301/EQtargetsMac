//
//  RingMapping.swift
//  EQtargets (macOS)
//
//  The app's (read-only) view of the driver's shared-memory ring, and the
//  watchdog that notices when that view has gone dead.
//
//  Open: shm_open(EQT_RING_SHM_NAME, O_RDONLY) → fstat (size ≥ the ring; macOS
//  rounds shm sizes up to the VM page, so "≥" not "==") → mmap(PROT_READ,
//  MAP_SHARED). The fd is closed right away; the mapping keeps the object alive.
//
//  Why a watchdog: the driver normally re-attaches to the SAME shm object when
//  coreaudiod restarts (it bumps `generation`, which RingReader handles). But if
//  it ever has to unlink and recreate the object (wrong size from an older
//  build, EACCES), our mapping still points at the orphaned old object: its
//  header simply never advances again while the virtual device plays. The only
//  cure is to re-open by name — which is what `RingWatchdog` triggers.
//

import Darwin
import Foundation

final class RingMapping {

    enum OpenError: Error, Equatable {
        /// No ring object: the driver isn't loaded, or failed to create it.
        case notFound
        case permissionDenied
        case tooSmall(Int)
        case failed(String)

        var userMessage: String {
            switch self {
            case .notFound:
                return "EQtargets Audio is installed but isn't sharing audio yet. Restart your Mac or reinstall the driver."
            case .permissionDenied:
                return "EQtargets can't read the EQtargets Audio driver's audio (permission denied). Reinstall the driver."
            case .tooSmall:
                return "The EQtargets Audio driver is a different version than this app. Reinstall the driver."
            case .failed(let why):
                return "EQtargets can't read the EQtargets Audio driver's audio (\(why))."
            }
        }
    }

    let header: UnsafePointer<EQTRingHeader>
    private let base: UnsafeMutableRawPointer
    private let length: Int
    private let isHeap: Bool

    private init(base: UnsafeMutableRawPointer, length: Int, isHeap: Bool) {
        self.base = base
        self.length = length
        self.isHeap = isHeap
        header = UnsafePointer(base.assumingMemoryBound(to: EQTRingHeader.self))
    }

    deinit {
        if isHeap { base.deallocate() } else { munmap(base, length) }
    }

    /// Opens the driver's ring read-only. Never creates it (only the driver does).
    static func open(name: String = EQT_RING_SHM_NAME) -> Result<RingMapping, OpenError> {
        guard let shmOpen = shmOpenReadOnly else { return .failure(.failed("shm_open unavailable")) }
        let fd = name.withCString { shmOpen($0, O_RDONLY) }
        guard fd >= 0 else {
            let e = errno
            switch e {
            case ENOENT: return .failure(.notFound)
            case EACCES: return .failure(.permissionDenied)
            default: return .failure(.failed(String(cString: strerror(e))))
            }
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .failure(.failed("fstat: \(String(cString: strerror(errno)))")) }
        let total = Int(EQTRingTotalBytes())
        guard Int(st.st_size) >= total else { return .failure(.tooSmall(Int(st.st_size))) }
        let p = mmap(nil, total, PROT_READ, MAP_SHARED, fd, 0)
        guard let p, p != MAP_FAILED else { return .failure(.failed("mmap: \(String(cString: strerror(errno)))")) }
        return .success(RingMapping(base: p, length: total, isHeap: false))
    }

    /// An in-process ring (zeroed, page aligned) for the offline self-test: the
    /// test's writer thread plays the driver through `mutableHeader`.
    static func inProcess() -> RingMapping {
        let total = Int(EQTRingTotalBytes())
        let p = UnsafeMutableRawPointer.allocate(byteCount: total, alignment: 16_384)
        p.initializeMemory(as: UInt8.self, repeating: 0, count: total)
        return RingMapping(base: p, length: total, isHeap: true)
    }

    /// Writable header — only for an `inProcess()` ring.
    var mutableHeader: UnsafeMutablePointer<EQTRingHeader>? {
        isHeap ? base.assumingMemoryBound(to: EQTRingHeader.self) : nil
    }

    var isValid: Bool { EQTRingHeaderIsValid(header) != 0 }
    var writeHead: Int64 { EQTRingLoadWriteHead(header) }
    var lastWriteHostTime: UInt64 { EQTRingLoadLastWriteHostTime(header) }
    var generation: UInt64 { EQTRingLoadGeneration(header) }
    var sampleRate: Double { EQTRingLoadSampleRate(header) }
    var ioRunning: Bool { EQTRingLoadIORunning(header) != 0 }
    var ioBufferFrames: Int { Int(EQTRingLoadIOBufferFrames(header)) }

    /// True if both mappings currently show identical header bytes — i.e.
    /// re-opening by name gave us the same (dead) object, not a new one.
    func hasSameHeaderBytes(as other: RingMapping) -> Bool {
        memcmp(base, other.base, MemoryLayout<EQTRingHeader>.size) == 0
    }

    // shm_open is variadic, which Swift cannot call. Without O_CREAT the
    // optional mode argument is never read, so calling it through a
    // two-argument C pointer is ABI-safe (named arguments travel in registers
    // on arm64 and x86_64 alike). Read-only open is all the app ever needs.
    private typealias ShmOpenReadOnly = @convention(c) (UnsafePointer<CChar>, Int32) -> Int32
    private static let shmOpenReadOnly: ShmOpenReadOnly? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "shm_open") else { return nil }   // RTLD_DEFAULT
        return unsafeBitCast(sym, to: ShmOpenReadOnly.self)
    }()
}

/// Decides when a mapped ring looks dead. Fed at ~2 Hz while the output runs.
struct RingWatchdog: Equatable {
    /// How long the header may stay frozen (while the virtual device runs) or
    /// invalid before a re-open is attempted.
    var limitSeconds = 2.0
    private var lastHead: Int64 = -1
    private var lastStamp: UInt64 = 0
    private var frozenFor = 0.0
    private var invalidFor = 0.0

    mutating func reset() {
        lastHead = -1
        lastStamp = 0
        frozenFor = 0
        invalidFor = 0
    }

    /// `deviceRunning`: the virtual device reports IO running somewhere, so the
    /// driver SHOULD be writing. Returns true when the mapping should be re-opened.
    mutating func observe(valid: Bool, head: Int64, stamp: UInt64, deviceRunning: Bool, dt: Double) -> Bool {
        let step = dt.isFinite && dt > 0 ? dt : 0
        if !valid {
            invalidFor += step
            frozenFor = 0
        } else {
            invalidFor = 0
            let advanced = head != lastHead || stamp != lastStamp
            if advanced || !deviceRunning { frozenFor = 0 } else { frozenFor += step }
        }
        lastHead = head
        lastStamp = stamp
        return invalidFor >= limitSeconds || frozenFor >= limitSeconds
    }
}
