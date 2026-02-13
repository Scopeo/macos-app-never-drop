protocol AudioSource: AnyObject, Sendable {
    var sampleRate: Double { get }
    func drainSystemSamples() -> [Float]
    func drainMicSamples() -> [Float]
}
