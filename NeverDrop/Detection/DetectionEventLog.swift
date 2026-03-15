import CoreAudio
import Foundation

struct DetectionEvent: Sendable {
    let timestamp: Date
    let kind: Kind
    let detail: String

    enum Kind: String, Sendable {
        case micStatusChange
        case deviceListChange
        case stateTransition
        case probeResult
        case userAction
        case cooldownEvent
        case debounceEvent
    }
}

final class DetectionEventLog: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.draftnrun.NeverDrop.DetectionEventLog")
    private var buffer: [DetectionEvent] = []
    private let capacity: Int

    init(capacity: Int = 200) {
        self.capacity = capacity
    }

    func log(_ kind: DetectionEvent.Kind, _ detail: String) {
        let event = DetectionEvent(timestamp: Date(), kind: kind, detail: detail)
        queue.sync {
            buffer.append(event)
            if buffer.count > capacity {
                buffer.removeFirst(buffer.count - capacity)
            }
        }
    }

    func snapshot() -> [DetectionEvent] {
        queue.sync { buffer }
    }

    func deviceSnapshot() -> [[String: Any]] {
        let deviceIDs = MicrophoneMonitor.allInputDeviceIDs()
        return deviceIDs.map { id in
            var info: [String: Any] = ["deviceID": id]
            info["name"] = MicrophoneMonitor.deviceName(id) ?? "unknown"
            info["isRunning"] = MicrophoneMonitor.isDeviceRunning(id)
            info["isRunningLocally"] = MicrophoneMonitor.isDeviceRunningLocally(id)
            return info
        }
    }
}
