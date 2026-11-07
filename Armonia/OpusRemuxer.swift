import Foundation
import AudioToolbox

/// Converte un file WebM con audio Opus (formato di YouTube, itag 251) in un file CAF,
/// che iOS riproduce in modo nativo. L'audio NON viene ricompresso: i pacchetti Opus
/// vengono solo spostati da un contenitore all'altro, quindi la qualità resta identica.
enum OpusRemuxer {
    enum RemuxError: LocalizedError {
        case notOpus, noPackets, lacing, audioFile(OSStatus)

        var errorDescription: String? {
            switch self {
            case .notOpus: return "Il file non contiene audio Opus."
            case .noPackets: return "Il file Opus è vuoto o danneggiato."
            case .lacing: return "Formato WebM non supportato."
            case .audioFile(let s): return "Errore nella scrittura dell'audio (\(s))."
            }
        }
    }

    struct Parsed {
        var channels: UInt32 = 2
        var sampleRate: Double = 48000
        var codecPrivate: Data?
        var isOpus = false
        var packets: [Range<Int>] = []
    }

    // MARK: - Lettura WebM (EBML)

    private static let masters: Set<UInt32> = [
        0x18538067, // Segment
        0x1654AE6B, // Tracks
        0xAE,       // TrackEntry
        0xE1,       // Audio
        0x1F43B675, // Cluster
        0xA0,       // BlockGroup
    ]

    static func parse(_ d: Data) throws -> Parsed {
        var p = Parsed()
        try d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            var i = 0

            func readID() -> UInt32? {
                guard i < n else { return nil }
                let first = b[i]
                var len = 1
                var mask: UInt8 = 0x80
                while len <= 4 && (first & mask) == 0 { mask >>= 1; len += 1 }
                guard len <= 4, i + len <= n else { return nil }
                var v: UInt32 = 0
                for k in 0..<len { v = (v << 8) | UInt32(b[i + k]) }
                i += len
                return v
            }

            /// Dimensione dell'elemento; nil = sconosciuta (fino alla fine del contenitore).
            func readSize() -> Int?? {
                guard i < n else { return .none }
                let first = b[i]
                var len = 1
                var mask: UInt8 = 0x80
                while len <= 8 && (first & mask) == 0 { mask >>= 1; len += 1 }
                guard len <= 8, i + len <= n else { return .none }
                var v = UInt64(first & (mask &- 1))
                var allOnes = v == UInt64(mask &- 1)
                for k in 1..<len {
                    v = (v << 8) | UInt64(b[i + k])
                    if b[i + k] != 0xFF { allOnes = false }
                }
                i += len
                if allOnes { return .some(nil) }
                return .some(Int(clamping: v))
            }

            func readUInt(_ size: Int) -> UInt64 {
                var v: UInt64 = 0
                for k in 0..<min(size, 8) { v = (v << 8) | UInt64(b[i + k]) }
                return v
            }

            while i < n {
                guard let id = readID(), case .some(let sizeOpt) = readSize() else { break }
                if masters.contains(id) { continue }          // si entra nel contenitore
                guard let size = sizeOpt, i + size <= n else { break }
                switch id {
                case 0x86: // CodecID
                    let s = String(decoding: UnsafeRawBufferPointer(rebasing: raw[i..<(i + size)]), as: UTF8.self)
                    if s.hasPrefix("A_OPUS") { p.isOpus = true }
                case 0x63A2: // CodecPrivate (OpusHead)
                    p.codecPrivate = d.subdata(in: (d.startIndex + i)..<(d.startIndex + i + size))
                case 0x9F: // Channels
                    p.channels = UInt32(readUInt(size))
                case 0xB5: // SamplingFrequency (float 4 o 8 byte)
                    if size == 4 {
                        p.sampleRate = Double(Float(bitPattern: UInt32(readUInt(4))))
                    } else if size == 8 {
                        p.sampleRate = Double(bitPattern: readUInt(8))
                    }
                case 0xA3, 0xA1: // SimpleBlock / Block
                    var j = i
                    // numero della traccia (vint), timecode (2 byte), flag (1 byte)
                    let first = b[j]
                    var len = 1
                    var mask: UInt8 = 0x80
                    while len <= 8 && (first & mask) == 0 { mask >>= 1; len += 1 }
                    j += len + 2
                    let flags = b[j]
                    j += 1
                    if flags & 0x06 != 0 { throw RemuxError.lacing }
                    if j < i + size { p.packets.append((d.startIndex + j)..<(d.startIndex + i + size)) }
                default:
                    break
                }
                i += size
            }
        }
        if !p.isOpus && p.codecPrivate?.starts(with: Array("OpusHead".utf8)) == true { p.isOpus = true }
        guard p.isOpus else { throw RemuxError.notOpus }
        guard !p.packets.isEmpty else { throw RemuxError.noPackets }
        if p.sampleRate <= 0 { p.sampleRate = 48000 }
        if p.channels == 0 { p.channels = 2 }
        return p
    }

    /// Campioni (a 48 kHz) contenuti in un pacchetto Opus, letti dal byte TOC (RFC 6716 §3.1).
    static func samples(inPacket d: Data, _ r: Range<Int>) -> UInt32 {
        guard !r.isEmpty else { return 960 }
        let toc = d[r.lowerBound]
        let config = Int(toc >> 3)
        let tenthsOfMs: Int
        switch config {
        case 0...11: tenthsOfMs = [100, 200, 400, 600][config % 4]
        case 12...15: tenthsOfMs = [100, 200][config % 2]
        default: tenthsOfMs = [25, 50, 100, 200][config % 4]
        }
        let frames: Int
        switch toc & 0x03 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default: frames = r.count > 1 ? Int(d[r.lowerBound + 1] & 0x3F) : 1
        }
        return UInt32(tenthsOfMs * 48 / 10 * max(frames, 1))
    }

    // MARK: - Scrittura CAF

    static func convert(webm src: URL, to dst: URL) throws {
        let data = try Data(contentsOf: src, options: .mappedIfSafe)
        let parsed = try parse(data)

        let frameSizes = parsed.packets.map { samples(inPacket: data, $0) }
        let constant = Set(frameSizes).count == 1 ? frameSizes[0] : 0

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000,                 // Opus decodifica sempre a 48 kHz
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: constant,
            mBytesPerFrame: 0,
            mChannelsPerFrame: parsed.channels,
            mBitsPerChannel: 0,
            mReserved: 0)

        try? FileManager.default.removeItem(at: dst)
        var file: AudioFileID?
        var st = AudioFileCreateWithURL(dst as CFURL, kAudioFileCAFType, &asbd, .eraseFile, &file)
        guard st == noErr, let file else { throw RemuxError.audioFile(st) }
        defer { AudioFileClose(file) }

        // Campioni iniziali da scartare (pre-skip), indicati nell'intestazione OpusHead.
        var preSkip: UInt32 = 312
        if let head = parsed.codecPrivate, head.count >= 12 {
            preSkip = UInt32(head[head.startIndex + 10]) | (UInt32(head[head.startIndex + 11]) << 8)
        }

        var packetIndex: Int64 = 0
        let batch = 512
        var start = 0
        while start < parsed.packets.count {
            let end = min(start + batch, parsed.packets.count)
            var buffer = Data()
            var descs: [AudioStreamPacketDescription] = []
            descs.reserveCapacity(end - start)
            for k in start..<end {
                let r = parsed.packets[k]
                descs.append(AudioStreamPacketDescription(
                    mStartOffset: Int64(buffer.count),
                    mVariableFramesInPacket: constant == 0 ? frameSizes[k] : 0,
                    mDataByteSize: UInt32(r.count)))
                buffer.append(data[r])
            }
            var count = UInt32(descs.count)
            st = buffer.withUnsafeBytes { ptr in
                AudioFileWritePackets(file, false, UInt32(buffer.count), &descs, packetIndex, &count, ptr.baseAddress!)
            }
            guard st == noErr else { throw RemuxError.audioFile(st) }
            packetIndex += Int64(count)
            start = end
        }

        let totalFrames = frameSizes.reduce(Int64(0)) { $0 + Int64($1) }
        var info = AudioFilePacketTableInfo(
            mNumberValidFrames: max(0, totalFrames - Int64(preSkip)),
            mPrimingFrames: Int32(preSkip),
            mRemainderFrames: 0)
        _ = AudioFileSetProperty(file, kAudioFilePropertyPacketTableInfo,
                                 UInt32(MemoryLayout<AudioFilePacketTableInfo>.size), &info)
    }
}
