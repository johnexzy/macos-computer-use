import UseUIProtocol
import Foundation

/// Checks the limit while accumulating, including the eventual LF byte.
public struct LineFramer {
    private var partial = Data()
    public init() {}

    public mutating func append(_ bytes: Data) throws -> [Data] {
        var lines: [Data] = []
        for byte in bytes {
            guard partial.count < Limits.maxFrameBytes else { throw ContractError("frame exceeds limit") }
            partial.append(byte)
            if byte == 10 {
                lines.append(partial)
                partial = Data()
            } else if partial.count == Limits.maxFrameBytes {
                throw ContractError("frame exceeds limit before LF")
            }
        }
        return lines
    }

    public func finish() throws {
        guard partial.isEmpty else { throw ContractError("truncated final frame") }
    }
}
