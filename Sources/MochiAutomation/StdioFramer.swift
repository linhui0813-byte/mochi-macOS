import Foundation

/// Splits a byte stream into newline-terminated requests of at most `limit` bytes.
/// A longer line is reported once as `.oversized` and its bytes are discarded up to the next newline.
public struct MCPStdioFramer {
    public enum Line: Equatable { case request(Data), oversized }
    public let limit: Int
    private var buffer = Data()
    private var discarding = false
    public init(limit: Int = LocalControl.maxFrame) { self.limit = limit }
    public mutating func feed(_ chunk: Data) -> [Line] {
        var lines: [Line] = [], rest = chunk[...]
        while let newline = rest.firstIndex(of:10) {
            let piece = rest[rest.startIndex..<newline]
            if discarding || buffer.count + piece.count > limit { lines.append(.oversized) }
            else { buffer.append(contentsOf:piece); lines.append(.request(buffer)) }
            buffer.removeAll(keepingCapacity:true); discarding = false
            rest = rest[rest.index(after:newline)...]
        }
        if !discarding {
            if buffer.count + rest.count > limit { discarding = true; buffer.removeAll(keepingCapacity:true) }
            else { buffer.append(contentsOf:rest) }
        }
        return lines
    }
    /// The final request when input ends without a newline.
    public mutating func finish() -> Line? {
        defer { buffer.removeAll(); discarding = false }
        if discarding { return .oversized }
        return buffer.isEmpty ? nil : .request(buffer)
    }
}
