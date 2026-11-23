import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif
#if canImport(Glibc)
import Glibc
#endif

public enum DetectedTextEncoding: String, Sendable, Equatable {
    case utf8BOM = "UTF-8 (BOM)"
    case utf8 = "UTF-8"
    case utf16LE = "UTF-16 LE"
    case utf16BE = "UTF-16 BE"
    case gb18030 = "GB18030/GBK"
    case big5 = "Big5"
    case shiftJIS = "Shift-JIS"
    case windows1252 = "Windows-1252"
}

public struct DecodedSubtitleText: Sendable, Equatable {
    public let text: String
    public let encoding: DetectedTextEncoding

    public init(text: String, encoding: DetectedTextEncoding) {
        self.text = text
        self.encoding = encoding
    }
}

/// Automatically detects and decodes UTF-8, UTF-16, GB18030/GBK, Big5, Shift-JIS, and Latin-1 subtitles
/// without mojibake on both Ubuntu Linux and Apple tvOS.
public enum SubtitleEncodingDetector {
    public static func decode(_ rawData: Data) -> DecodedSubtitleText {
        guard !rawData.isEmpty else {
            return DecodedSubtitleText(text: "", encoding: .utf8)
        }

        let data = Data(rawData) // Normalize startIndex == 0

        // 1. BOM checks
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            let body = Data(data.dropFirst(3))
            if let str = String(data: body, encoding: .utf8) {
                return DecodedSubtitleText(text: normalizeLineEndings(str), encoding: .utf8BOM)
            }
        }
        if data.count >= 2, data[0] == 0xFF, data[1] == 0xFE {
            let body = Data(data.dropFirst(2))
            if let str = String(data: body, encoding: .utf16LittleEndian) {
                return DecodedSubtitleText(text: normalizeLineEndings(str), encoding: .utf16LE)
            }
        }
        if data.count >= 2, data[0] == 0xFE, data[1] == 0xFF {
            let body = Data(data.dropFirst(2))
            if let str = String(data: body, encoding: .utf16BigEndian) {
                return DecodedSubtitleText(text: normalizeLineEndings(str), encoding: .utf16BE)
            }
        }

        // 2. Strict UTF-8 check (almost never false-positives on raw GBK/Big5 Chinese files)
        if let utf8Str = String(data: data, encoding: .utf8), !looksLikeUTF16WithoutBOM(data) {
            return DecodedSubtitleText(text: normalizeLineEndings(utf8Str), encoding: .utf8)
        }

        // 3. Heuristic UTF-16 without BOM
        if looksLikeUTF16WithoutBOM(data) {
            let leNulls = stride(from: 1, to: min(data.count, 512), by: 2).filter { data[$0] == 0 }.count
            let beNulls = stride(from: 0, to: min(data.count, 512), by: 2).filter { data[$0] == 0 }.count
            if leNulls >= beNulls, let str = String(data: data, encoding: .utf16LittleEndian) {
                return DecodedSubtitleText(text: normalizeLineEndings(str), encoding: .utf16LE)
            }
            if let str = String(data: data, encoding: .utf16BigEndian) {
                return DecodedSubtitleText(text: normalizeLineEndings(str), encoding: .utf16BE)
            }
        }

        // 4. Legacy CJK candidates: score GB18030, Big5, Shift-JIS
        var best: (text: String, encoding: DetectedTextEncoding, score: Double)?
        let candidates: [(DetectedTextEncoding, String)] = [
            (.gb18030, "GB18030"),
            (.big5, "BIG5"),
            (.shiftJIS, "SHIFT_JIS")
        ]

        for (enc, iconvName) in candidates {
            if let decoded = decodeLegacy(data, encoding: enc, iconvName: iconvName) {
                let score = scoreDecodedText(decoded, encoding: enc)
                if best == nil || score > best!.score {
                    best = (decoded, enc, score)
                }
            }
        }

        if let winner = best {
            return DecodedSubtitleText(text: normalizeLineEndings(winner.text), encoding: winner.encoding)
        }

        // 5. Lossless fallback to Windows-1252 / ISO Latin-1
        let fallback = String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
        return DecodedSubtitleText(text: normalizeLineEndings(fallback), encoding: .windows1252)
    }

    private static func looksLikeUTF16WithoutBOM(_ data: Data) -> Bool {
        let sampleLen = min(data.count, 512)
        guard sampleLen >= 8 else { return false }
        let nullCount = data[0..<sampleLen].filter { $0 == 0 }.count
        return Double(nullCount) / Double(sampleLen) > 0.2
    }

    private static func normalizeLineEndings(_ str: String) -> String {
        str.replacingOccurrences(of: "\r\n", with: "\n")
           .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func scoreDecodedText(_ text: String, encoding: DetectedTextEncoding) -> Double {
        var score: Double = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) {
                score += 3.0 // Common CJK Unified Ideographs
            } else if (0x3000...0x303F).contains(v) || (0xFF01...0xFF5E).contains(v) {
                score += 2.0 // Full-width CJK punctuation & forms (，。！？)
            } else if (0x3040...0x30FF).contains(v) {
                score += (encoding == .shiftJIS ? 3.5 : 0.2) // Standard full-width Hiragana/Katakana
            } else if (0xFF61...0xFF9F).contains(v) {
                score -= 4.0 // Half-width Katakana (classic Shift-JIS false-positive mojibake on GBK bytes)
            } else if (0x20...0x7E).contains(v) || v == 0x0A || v == 0x09 {
                score += 0.1 // Printable ASCII / newline
            } else if v == 0xFFFD || v < 0x20 || (0xE000...0xF8FF).contains(v) {
                score -= 10.0 // Replacement char, control char, private-use area
            } else {
                score -= 2.0
            }
        }
        if encoding == .gb18030 {
            score += 0.5
        }
        return score
    }

    private static func decodeLegacy(_ data: Data, encoding: DetectedTextEncoding, iconvName: String) -> String? {
        #if canImport(CoreFoundation) && !os(Linux)
        let cfEnc: CFStringEncodings
        switch encoding {
        case .gb18030: cfEnc = .GB_18030_2000
        case .big5: cfEnc = .big5
        case .shiftJIS: cfEnc = .shiftJIS
        default: return nil
        }
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEnc.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: nsEnc))
        #elseif canImport(Glibc)
        return iconvDecode(data, from: iconvName)
        #else
        return nil
        #endif
    }

    #if canImport(Glibc)
    private static func iconvDecode(_ data: Data, from sourceCharset: String) -> String? {
        let cd = iconv_open("UTF-8", sourceCharset)
        let invalid = iconv_t(bitPattern: -1)
        guard let handle = cd, handle != invalid else { return nil }
        defer { iconv_close(handle) }

        return data.withUnsafeBytes { rawBuf -> String? in
            guard let basePtr = rawBuf.baseAddress else { return "" }
            var inBuf: UnsafeMutablePointer<CChar>? = UnsafeMutablePointer(mutating: basePtr.assumingMemoryBound(to: CChar.self))
            var inBytesLeft: Int = data.count

            var output = Data()
            var outChunk = [CChar](repeating: 0, count: max(4096, data.count * 2))

            while inBytesLeft > 0 {
                let produced: Int? = outChunk.withUnsafeMutableBufferPointer { outBufPtr in
                    var outPtr = outBufPtr.baseAddress
                    var outBytesLeft = outBufPtr.count
                    let res = iconv(handle, &inBuf, &inBytesLeft, &outPtr, &outBytesLeft)
                    let written = outBufPtr.count - outBytesLeft
                    if res == -1 {
                        if errno == E2BIG {
                            return written
                        }
                        // Illegal or incomplete sequence -> reject this charset
                        return nil
                    }
                    return written
                }
                guard let count = produced else { return nil }
                if count > 0 {
                    outChunk.withUnsafeBytes { ptr in
                        output.append(ptr.bindMemory(to: UInt8.self).baseAddress!, count: count)
                    }
                }
            }

            return String(data: output, encoding: .utf8)
        }
    }
    #endif
}
