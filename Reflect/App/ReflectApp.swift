import SwiftUI

#if DEBUG
// KPI-01 probe: true process start (via sysctl) → first frame.
private func processStartDate() -> Date? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
    let tv = info.kp_proc.p_starttime
    return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
}
#endif

@main
struct ReflectApp: App {
    var body: some Scene {
        WindowGroup {
            AppShell()
                .frame(minWidth: 900, minHeight: 620)
                #if DEBUG
                .onAppear {
                    let ms = processStartDate().map {
                        Date.now.timeIntervalSince($0) * 1000
                    } ?? -1
                    print("KPI-01 first frame: \(String(format: "%.0f", ms)) ms")
                    fflush(stdout)
                }
                #endif
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
    }
}
