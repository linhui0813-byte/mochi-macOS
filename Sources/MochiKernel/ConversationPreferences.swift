import Foundation

public enum CoachingStyle: String, Codable, CaseIterable { case natural, gentle, direct }
public struct ConversationPreferences: Codable, Equatable {
    public var speed: Double?
    public var coaching: CoachingStyle = .natural
    public init() {}
    public static let speedRange = 0.25...1.5
    public static func isValidSpeed(_ speed: Double) -> Bool { speed.isFinite && speedRange.contains(speed) }
    private enum CodingKeys: String, CodingKey { case speed, coaching }
    public init(from decoder: Decoder) throws {
        // Out-of-range or unknown stored values fall back to defaults so an old library still opens; the log says so.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try? c.decodeIfPresent(Double.self, forKey: .speed)
        speed = decoded.flatMap { Self.isValidSpeed($0) ? $0 : nil }
        if c.contains(.speed), (try? c.decodeNil(forKey: .speed)) != true, speed == nil {
            MochiLog.app.notice("A conversation's stored speech speed was invalid; using the default")
        }
        let style = try? c.decodeIfPresent(String.self, forKey: .coaching)
        coaching = style.flatMap(CoachingStyle.init(rawValue:)) ?? .natural
        // A wrong type decodes as nil, so presence is checked separately from the value.
        if c.contains(.coaching), (try? c.decodeNil(forKey: .coaching)) != true,
            style.flatMap(CoachingStyle.init(rawValue:)) == nil
        {
            MochiLog.app.notice("A conversation's stored coaching style was unknown; using natural")
        }
    }
    public func validate() throws {
        if let speed {
            guard Self.isValidSpeed(speed) else {
                throw AppFailure(
                    "Speech speed must be between \(Self.speedRange.lowerBound) and \(Self.speedRange.upperBound).")
            }
        }
    }
}
