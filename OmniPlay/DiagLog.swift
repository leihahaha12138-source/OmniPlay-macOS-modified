import Foundation

/// 接收外部豆瓣同步脚本完成的通知，广播给全 App 刷新海报墙。
///
/// ★ 为什么需要：豆瓣评分/海报是由**外部 Python 脚本**（`douban_sync.py`）
///   直接写 sqlite 的。App 用 GRDB 的 `DatabaseQueue` 而非 `ValueObservation`，
///   对外部进程的写操作**毫无感知** —— 表现就是「数据已入库，界面永远空白，
///   必须重启 App」。脚本发 Darwin 通知，这里把它转成本地 `libraryUpdated`。
///
/// ★ 为什么必须用 CFNotificationCenter 而非 DistributedNotificationCenter：
///   后者在新版 macOS 上对未注册的应用不可靠，实测发出后 App **完全收不到**
///   （日志无任何记录）。Darwin 通知的接收端要用
///   `CFNotificationCenterGetDarwinNotifyCenter()`，两者不是同一套东西。
final class DoubanSyncObserver {
    static let shared = DoubanSyncObserver()

    /// 与 `douban_sync.py` 的 `NOTIFY_NAME` 保持一致。
    private static let notifyName = "com.omniplay.doubanSyncDone" as CFString

    private var started = false

    private init() {}

    /// 开始监听。幂等，可多处调用。
    func start() {
        guard !started else { return }
        started = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                // 回调不在主线程，必须切回主线程再动通知中心
                guard let observer else { return }
                let obj = Unmanaged<DoubanSyncObserver>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { obj.handleSyncDone() }
            },
            Self.notifyName,
            nil,
            .deliverImmediately)
        DiagLog.write("豆瓣", "已监听外部同步完成通知（\(Self.notifyName)）")
    }

    fileprivate func handleSyncDone() {
        DiagLog.write("豆瓣", "收到外部同步完成通知 → 刷新海报墙")
        NotificationCenter.default.post(name: .libraryUpdated, object: nil)
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque())
    }
}

/// 诊断日志：把关键运行信息落到磁盘，便于事后定位问题。
///
/// 为什么需要它：App 里的 `print()` 只进 stdout，`log stream` 之类的系统工具
/// 抓不到（SwiftUI App 启动后没有可用的 stdout 通道）。而调试播放器窗口缩放
/// 这类问题时，唯一的依据就是运行时数据 —— 看不到就只能猜。
///
/// 写入位置：`~/Library/Logs/OmniPlay-Debug/diag.log`（每次启动追加，不覆盖）
enum DiagLog {
    private static let lock = NSLock()
    private static var url: URL? = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/OmniPlay-Debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diag.log")
    }()

    /// 追加一行。写失败绝不抛错——诊断设施不该影响主流程。
    static func write(_ tag: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let url else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
        let thread = Thread.isMainThread ? "main" : "bg"
        let line = "[\(ts)][\(thread)][\(tag)] \(message)\n"
        // 不做 flush/fsync：这里每秒最多几十行，开销可忽略。
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) { handle.write(data) }
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func readAll() -> String {
        guard let url else { return "(日志路径未初始化)" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "(暂无日志)"
    }
}
