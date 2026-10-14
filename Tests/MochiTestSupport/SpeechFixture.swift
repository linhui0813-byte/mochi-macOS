import Foundation

/// Public libfvad test speech, never a user's microphone recording.
public enum SpeechFixture {
    public static let pcm: Data = {
        let url = Bundle.module.url(forResource: "speech-24k.pcm", withExtension: "base64", subdirectory: "Resources")!
        return Data(base64Encoded: try! Data(contentsOf: url), options: .ignoreUnknownCharacters)!
    }()
    public static func voiced(frames: Int) -> Data {
        var data = Data()
        while data.count < frames * 960 { data.append(pcm) }
        return Data(data.prefix(frames * 960))
    }
}
