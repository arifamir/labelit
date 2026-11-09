import Foundation
#if os(Linux)
import CLinux
#endif

enum FileDates {
    /// When the file came to be at this place: its birth time. Foundation's creationDate is that on a Mac, but on Linux
    /// it's the status-change time (it moves on every rename), so Linux asks statx.
    static func created(atPath path: String) -> Date? {
        #if os(Linux)
        let seconds = labelit_birth_time(path)
        if seconds >= 0 { return Date(timeIntervalSince1970: seconds) }
        #endif
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
    }

    /// When the file arrived in its folder. Not always its creation date: AirDrop gives a received photo the date the
    /// photo was taken, so on a Mac the date it was added to the folder (Finder's "Date Added") counts too.
    static func arrived(atPath path: String) -> Date? {
        var dates = [created(atPath: path)]
        #if os(macOS)
        dates.append(try? URL(fileURLWithPath: path).resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate)
        #endif
        return dates.compactMap { $0 }.max()
    }
}
