import Foundation

enum AudioEncoding {
    static func floatToPCMS16LE(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * Float(Int16.max))
            var le = int16.littleEndian
            data.append(Data(bytes: &le, count: 2))
        }
        return data
    }
}
