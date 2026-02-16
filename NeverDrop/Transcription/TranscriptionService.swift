import Foundation

@MainActor
protocol TranscriptionService: AnyObject {
    var isReady: Bool { get }
    var selectedLanguage: String? { get set }
    func prepare() async throws
    func startTranscribing(audioSource: any AudioSource, writer: any TranscriptionWriting)
    func stopTranscribing()
}
