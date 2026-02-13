import os

extension Logger {
    static func app(category: String) -> Logger {
        Logger(subsystem: "com.draftnrun.NeverDrop", category: category)
    }
}
