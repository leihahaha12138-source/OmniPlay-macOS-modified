import Foundation
import AppKit
import WebKit

/// 豆瓣登录态管理：在 App 内弹出网页登录，登录成功后自动取出 `dbcl2` 写成本地凭据文件，
/// 供外部刮削脚本使用。省去「浏览器 → 开发者工具 → 请求标头 → 复制 Cookie」这套繁琐流程。
///
/// 关键实现要点（踩过的坑）：
/// 1. **必须用 `WKHTTPCookieStore.getAllCookies()`**，不能用页面里的 `document.cookie`
///    —— 豆瓣的 `dbcl2` 是 HttpOnly，JS 读不到。
/// 2. **必须与登录时用同一个 data store**（`WKWebsiteDataStore.default()`）。
///    官方 demo 里 `.nonPersistent()` 与读取端不一致会导致读不到。
/// 3. 只取 `dbcl2`，其余 cookie 丢弃，最小化凭据暴露面。
enum DoubanLoginService {

    /// 凭据文件路径：与外部脚本 `~/.omniplay-douban-sync/douban_cookie.txt` 同格式。
    static var credentialDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".omniplay-douban-sync", isDirectory: true)
    }

    static var credentialFile: URL {
        credentialDirectory.appendingPathComponent("douban-cookie.txt")
    }

    /// 登录页地址。
    ///
    /// 豆瓣已把账号中心迁到 `accounts.douban.com`：
    /// `https://www.douban.com/login` → 302 → `https://accounts.douban.com/passport/login`
    /// 旧地址 `passport.douban.com` 在当前网络下握手失败（实测 TLS 断连），
    /// 因此这里直接用可用地址，避免 302 前一步就失败。
    static let loginURL = URL(string: "https://accounts.douban.com/passport/login")!

    /// 读取已保存的凭据，nil 或空串表示未登录。
    static func loadCredential() -> String? {
        guard let text = try? String(contentsOf: credentialFile, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 是否已登录（凭据存在且包含 dbcl2）。
    ///
    /// ★ 注意：这只说明「文件里有 dbcl2」，**不代表 cookie 还有效**（约 30 天过期）。
    /// 要确认真伪用 `verify(cookie:)`。
    static var isLoggedIn: Bool {
        guard let c = loadCredential() else { return false }
        return c.contains("dbcl2=")
    }

    /// 拼装请求头用的 cookie 串。
    ///
    /// ★ 豆瓣的 `dbcl2` 值**本身就带引号**：`dbcl2="uid:token"`。
    ///   这里若再补一对引号，会写成 `dbcl2=""uid:token""` —— 豆瓣解析失败，
    ///   uid 提取不出来、受限条目直接 404，而且外部同步脚本会一起失效。
    ///   先剥掉已有的引号再统一补一对，保证幂等。
    static func formatCookie(dbcl2 rawValue: String, bid: String?) -> String {
        let bare = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let bidPart = bid.map { "; bid=\($0)" } ?? ""
        return "dbcl2=\"\(bare)\"\(bidPart)"
    }

    /// 从 cookie 串里取豆瓣 uid。
    ///
    /// 格式 `dbcl2="uid:token"`，uid 是第一段数字。uid 用来定位个人主页取昵称。
    static func uid(from cookie: String) -> String? {
        guard let range = cookie.range(of: "dbcl2=\"") else { return nil }
        let after = cookie[range.upperBound...]
        // uid 是引号后第一个 `:` 之前的数字段
        let digits = after.prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    private static let browserUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

    /// 登录态检查结果。
    struct AccountState {
        /// cookie 确实还有效（豆瓣认了这个账号）。
        var valid: Bool
        /// 昵称。仅在 `valid` 为 true 时有值 —— 这是"取到昵称就等于真登录"的依据。
        var nickname: String?
    }

    /// 检查已保存的凭据：同时判定登录有效性**并**取回昵称。
    ///
    /// ★ 设计要点：一次请求同时给出两件事，靠**同一个页面**的两个信号。
    ///   请求 `www.douban.com/people/<uid>/`（自己的主页），判定：
    ///     1. 页面里有 `nav-user-account` → 豆瓣认了这个 cookie（登录有效）
    ///     2. 其中 `XX的账号` 的 XX → 就是昵称
    ///   实测三种情形（好 cookie / 坏 cookie / 匿名）下该标记**只为好 cookie 出现**，
    ///   所以「有昵称」等价于「登录成功」—— 这正是界面需要的强相关。
    ///
    /// ★ 为什么不用具体电影条目当探针：那是拿一部片当探针，语义错位、
    ///   且随豆瓣限流策略漂移（详见 git 记录）。自己主页既不绑片子也不是逆向接口。
    static func checkAccount(_ completion: @escaping (AccountState) -> Void) {
        guard let cookie = loadCredential(), !cookie.isEmpty else {
            completion(AccountState(valid: false, nickname: nil))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            completion(probe(cookie: cookie))
        }
    }

    /// 请求个人主页并解析登录标记与昵称。
    private static func probe(cookie: String) -> AccountState {
        // 局部名不要叫 uid：会遮蔽同名的 `uid(from:)` 方法
        guard let userID = uid(from: cookie),
              let url = URL(string: "https://www.douban.com/people/\(userID)/") else {
            DiagLog.write("豆瓣", "无法解析 uid，凭据格式可能已损坏")
            return AccountState(valid: false, nickname: nil)
        }
        var req = URLRequest(url: url)
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData

        let sem = DispatchSemaphore(value: 0)
        var state = AccountState(valid: false, nickname: nil)
        URLSession.shared.dataTask(with: req) { data, response, _ in
            defer { sem.signal() }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let data,
                  let html = String(data: data, encoding: .utf8) else { return }
            // ① 登录标记：只在豆瓣认了这个 cookie 时出现
            guard html.contains("nav-user-account") else { return }
            state.valid = true
            // ② 昵称：形如 <span>某用户昵称的账号</span>
            if let r = html.range(of: "的账号") {
                // 往前读到标签的 `>`，取其中纯文本
                let head = String(html[html.startIndex..<r.lowerBound])
                if let gt = head.lastIndex(of: ">") {
                    let raw = String(head[head.index(after: gt)...])
                    let name = raw.components(separatedBy: .whitespacesAndNewlines).joined()
                    if !name.isEmpty && name.count <= 40 { state.nickname = name }
                }
            }
        }.resume()
        // 请求自带 15s timeout，这里只是兜底上限
        _ = sem.wait(timeout: .now() + 16)
        DiagLog.write("豆瓣", "登录检查：\(state.valid ? "有效" : "无效/过期")"
                      + "，昵称=\(state.nickname ?? "无")")
        return state
    }

    /// 凭据写入时间，用于在设置页显示「上次登录」。
    static var credentialModifiedAt: Date? {
        try? FileManager.default.attributesOfItem(atPath: credentialFile.path)[.modificationDate] as? Date
    }

    /// 清除登录态：删凭据文件。
    static func clearCredential() {
        try? FileManager.default.removeItem(at: credentialFile)
    }

    /// 把抓到的 cookie 写成凭据文件，权限 0600。
    /// - Returns: 是否成功。
    @discardableResult
    static func writeCredential(cookie: String) -> Bool {
        guard cookie.contains("dbcl2=") else { return false }
        do {
            try FileManager.default.createDirectory(
                at: credentialDirectory, withIntermediateDirectories: true)
            // 先以 0600 创建再写，避免出现「先按默认权限建好、里面才写内容」的窗口。
            if !FileManager.default.fileExists(atPath: credentialFile.path) {
                FileManager.default.createFile(
                    atPath: credentialFile.path, contents: nil,
                    attributes: [.posixPermissions: 0o600])
            }
            try cookie.write(to: credentialFile, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: credentialFile.path)
            DiagLog.write("豆瓣", "已保存登录凭据（\(cookie.count) 字节）")
            return true
        } catch {
            DiagLog.write("豆瓣", "保存凭据失败：\(error)")
            return false
        }
    }
}

// MARK: - 登录窗口

/// 承载 `WKWebView` 的窗口，负责展示豆瓣登录页并在登录成功后回传 cookie。
final class DoubanLoginWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var progress: NSProgressIndicator!
    private var hintLabel: NSTextField!
    private var retryBtn: NSButton!
    private var done = false

    /// cookie 轮询定时器。**这是能否登录成功的关键，不能省。**
    ///
    /// 踩过的坑：只靠 `didFinish` 抓 cookie 不可靠。实测用户扫码登录成功、
    /// 页面已跳到个人主页（日志里能看出来），但 `didFinish` 一次都没触发 ——
    /// 豆瓣登录后的跳转有些走 JS 路由/局部导航，不产生顶层文档加载完成事件。
    /// 结果 dbcl2 已经在 cookie store 里，App 却完全不知道，点「关闭」就丢了。
    private var pollTimer: Timer?
    /// 上一次轮询看到的 cookie 名集合，用于只在变化时记日志（避免每秒刷屏）。
    private var lastCookieNames: Set<String> = []

    /// 登录成功回调（在主线程）。cookie 已是拼好的请求头形式。
    var onSuccess: ((String) -> Void)?
    /// 用户主动关闭且未登录。
    var onCancel: (() -> Void)?

    /// 弹出登录窗口。成功时回调 cookie 串。
    static func present(onSuccess: @escaping (String) -> Void,
                        onCancel: @escaping () -> Void) {
        let controller = DoubanLoginWindowController()
        // 需要保活：否则 NSWindowDelegate 会被释放，cookie 回调永不触发。
        DoubanLoginWindowController.active = controller
        controller.onSuccess = onSuccess
        controller.onCancel = onCancel
        controller.show()
    }

    private static var active: DoubanLoginWindowController?

    private func show() {
        // WKWebView 依赖 WebContent 进程，必须在 App 已激活后再创建，
        // 否则可能整页白屏（内容区渲染不出来）。
        NSApp.activate(ignoringOtherApps: true)

        let config = WKWebViewConfiguration()
        // ★ 必须用 .default()：登录页写入的 cookie 与后续读取必须同源。
        config.websiteDataStore = .default()

        webView = WKWebView(frame: .zero, configuration: config)
        webView!.navigationDelegate = self
        // WebView 必须能撑满，否则在 Auto Layout 下会被压成 0 宽高 → 整页白屏
        webView!.translatesAutoresizingMaskIntoConstraints = false

        let closeBtn = NSButton(title: "关闭", target: self, action: #selector(onClose))
        closeBtn.bezelStyle = .rounded
        closeBtn.translatesAutoresizingMaskIntoConstraints = false

        // 加载失败时可点此重试，不必重新编译 App。
        retryBtn = NSButton(title: "重新加载", target: self, action: #selector(onRetry))
        retryBtn.bezelStyle = .rounded
        retryBtn.isHidden = true
        retryBtn.translatesAutoresizingMaskIntoConstraints = false

        hintLabel = NSTextField(labelWithString: "请在下方完成登录（扫码或账号密码）。登录成功会自动保存。")
        hintLabel?.font = .systemFont(ofSize: 11)
        hintLabel?.textColor = .secondaryLabelColor
        hintLabel?.translatesAutoresizingMaskIntoConstraints = false

        progress = NSProgressIndicator()
        progress!.style = .spinning
        progress!.controlSize = .small
        progress!.isHidden = true
        progress!.translatesAutoresizingMaskIntoConstraints = false

        // ★ 关键：窗口内容视图用 NSView 并给足 frame，
        // 再用 Auto Layout 排子视图（之前 bar 与 web 都放在 y=0，web 盖住了 bar）。
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 680))
        content.addSubview(closeBtn)
        content.addSubview(retryBtn)
        content.addSubview(hintLabel!)
        content.addSubview(progress!)
        content.addSubview(webView!)
        content.translatesAutoresizingMaskIntoConstraints = false

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window?.title = "登录豆瓣"
        window?.contentView = content
        window?.delegate = self
        window?.center()

        let pad: CGFloat = 10
        NSLayoutConstraint.activate([
            closeBtn.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            closeBtn.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            closeBtn.widthAnchor.constraint(equalToConstant: 64),
            closeBtn.heightAnchor.constraint(equalToConstant: 26),

            hintLabel!.leadingAnchor.constraint(equalTo: closeBtn.trailingAnchor, constant: 10),
            hintLabel!.centerYAnchor.constraint(equalTo: closeBtn.centerYAnchor),
            hintLabel!.trailingAnchor.constraint(equalTo: progress!.leadingAnchor, constant: -8),

            retryBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            retryBtn.centerYAnchor.constraint(equalTo: closeBtn.centerYAnchor),
            retryBtn.widthAnchor.constraint(equalToConstant: 84),
            retryBtn.heightAnchor.constraint(equalToConstant: 26),

            progress!.trailingAnchor.constraint(equalTo: retryBtn.leadingAnchor, constant: -8),
            progress!.centerYAnchor.constraint(equalTo: closeBtn.centerYAnchor),
            progress!.widthAnchor.constraint(equalToConstant: 14),
            progress!.heightAnchor.constraint(equalToConstant: 14),

            // web 铺满 bar 下方
            webView!.topAnchor.constraint(equalTo: closeBtn.bottomAnchor, constant: pad),
            webView!.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView!.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView!.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // ★ 必须先清掉旧 cookie，再加载页面。
        //   WKWebsiteDataStore.default() 是**持久化**的：上次登录的 dbcl2 还在。
        //   若不清，轮询第一秒就会命中残留值 → 窗口 1 秒内自动关闭 → 用户根本
        //   没扫码就被告知「登录成功」（实测：12:58:11 显示、12:58:12 就保存了）。
        //   退出登录按钮只删凭据文件、不动 WebView store，所以点多少次都会秒关。
        clearStaleCookies { [weak self] in
            guard let self, !self.done else { return }
            DiagLog.write("豆瓣", "登录窗口已显示，开始加载 \(DoubanLoginService.loginURL.absoluteString)")
            let req = URLRequest(url: DoubanLoginService.loginURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 20)
            self.webView?.load(req)
            self.startPolling()
        }
    }

    /// 清掉豆瓣相关的旧 cookie，强制走一次真实登录。
    /// 必须在后台线程调用 `WKHTTPCookieStore` 的删除 API，完成后再回调主线程。
    private func clearStaleCookies(_ completion: @escaping () -> Void) {
        let store = webView?.configuration.websiteDataStore.httpCookieStore
        guard let store else { completion(); return }
        store.getAllCookies { cookies in
            // dbcl2 是登录态本身，bid 会带上旧身份；其余一律不动（免得清掉无关站点状态）
            let stale = cookies.filter { $0.name == "dbcl2" || $0.name == "bid" }
            guard !stale.isEmpty else {
                DispatchQueue.main.async { completion() }
                return
            }
            DiagLog.write("豆瓣", "清除旧登录 cookie：\(stale.map(\.name).joined(separator: ","))")
            let group = DispatchGroup()
            for c in stale {
                group.enter()
                store.delete(c) { group.leave() }
            }
            group.notify(queue: .main) { completion() }
        }
    }

    /// 每秒查一次 cookie store。不依赖任何导航回调，因此豆瓣怎么跳转都不影响。
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, !self.done else { return }
            self.attemptFetchCookie(from: self.webView, silentIfUnchanged: true)
        }
        // 防止滚动/跟踪模式下 timer 不触发
        if let t = pollTimer { RunLoop.main.add(t, forMode: .common) }
    }

    @objc private func onClose() {
        // ★ 关键：点「关闭」时**不能直接判定为未登录**。
        // 用户可能刚扫码成功、cookie 已写入 store，但轮询还没跑到这一刻。
        // 所以先做一次最终检查，拿到 dbcl2 就按成功处理。
        DiagLog.write("豆瓣", "用户点击关闭，最终检查 cookie")
        attemptFetchCookie(from: webView) { hasCookie in
            self.finish(cancel: !hasCookie)
        }
    }

    /// 重新加载登录页（供网络/地址异常时手动重试）。
    @objc private func onRetry() {
        DiagLog.write("豆瓣", "用户点击重新加载")
        retryBtn?.isHidden = true
        progress?.isHidden = false
        progress?.startAnimation(nil)
        // 重试同样要清旧 cookie，否则残留的 dbcl2 会被当成新登录
        clearStaleCookies { [weak self] in
            guard let self else { return }
            let req = URLRequest(url: DoubanLoginService.loginURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 20)
            self.webView?.load(req)
        }
    }

    private func finish(cancel: Bool) {
        guard !done else { return }
        done = true
        pollTimer?.invalidate()
        pollTimer = nil
        window?.orderOut(nil)
        window?.delegate = nil
        window = nil
        webView = nil
        if cancel {
            onCancel?()
        }
        DoubanLoginWindowController.active = nil
    }

    /// 点窗口左上角红点关闭：与「关闭」按钮同一条路径，同样先做最终 cookie 检查。
    /// 不接这个的话，点红点会静默消失，`active` 引用也不释放。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose()
        return false   // 关闭动作交给 onClose 里的 finish 统一处理
    }
}

extension DoubanLoginWindowController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progress?.isHidden = false
        progress?.startAnimation(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progress?.stopAnimation(nil)
        progress?.isHidden = true
        DiagLog.write("豆瓣", "页面加载完成：\(webView.url?.absoluteString ?? "?")，尝试读取 cookie")
        // 页面加载完成即尝试取一次 cookie —— 登录后豆瓣会立即写入 dbcl2。
        attemptFetchCookie(from: webView)
    }

    /// 加载失败（如网络不通、证书问题）时明确记录，否则表现为「一片白」而无从排查。
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        progress?.stopAnimation(nil)
        progress?.isHidden = true
        let ns = error as NSError
        DiagLog.write("豆瓣", "页面加载失败：\(ns.localizedDescription)（\(ns.code)）URL=\(webView.url?.absoluteString ?? "?")")
        hintLabel?.stringValue = "页面加载失败，可点右侧「重新加载」重试。"
        retryBtn?.isHidden = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        DiagLog.write("豆瓣", "导航失败：\(ns.localizedDescription)（\(ns.code)）")
    }

    /// 从 WebView 的 cookie store 里取 dbcl2，成功则保存并关闭窗口。
    ///
    /// 用 `getAllCookies`（而非 `document.cookie`）：dbcl2 是 HttpOnly，JS 不可读。
    /// - Parameters:
    ///   - silentIfUnchanged: 轮询时为 true，cookie 名没变化就不打日志。
    ///   - completion: 检查完成回调，`true` 表示已取到 dbcl2。
    private func attemptFetchCookie(from webView: WKWebView?,
                                    silentIfUnchanged: Bool = false,
                                    completion: ((Bool) -> Void)? = nil) {
        guard let webView else { completion?(false); return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            DispatchQueue.main.async {
                guard let self else { completion?(false); return }
                let names = Set(cookies.map(\.name))
                guard let dbcl2 = cookies.first(where: {
                    $0.name == "dbcl2" && !$0.value.isEmpty
                }) else {
                    // 只在 cookie 组成变化时记日志，否则每秒一行会把日志冲垮。
                    if names != self.lastCookieNames {
                        self.lastCookieNames = names
                        DiagLog.write("豆瓣", "尚未检测到 dbcl2（当前 cookie：\(names.isEmpty ? "无" : names.sorted().joined(separator: ","))）")
                    }
                    completion?(false)
                    return   // 还没登录，等下一次轮询/导航
                }
                // 只取 dbcl2 + bid，最小化凭据面。
                // ★ 用 formatCookie 统一处理引号：dbcl2 的值本身带引号，
                //   直接拼会写成 dbcl2=""uid:token""，豆瓣解析失败。
                let value = DoubanLoginService.formatCookie(
                    dbcl2: dbcl2.value,
                    bid: cookies.first(where: { $0.name == "bid" })?.value)
                if DoubanLoginService.writeCredential(cookie: value) {
                    DiagLog.write("豆瓣", "登录成功，cookie 已保存")
                    self.hintLabel?.stringValue = "登录成功，已保存。"
                    self.onSuccess?(value)
                    // 调用方（onClose）会负责 finish；导航/轮询路径这里直接收尾。
                    if completion == nil { self.finish(cancel: false) }
                } else {
                    self.hintLabel?.stringValue = "已检测到登录，但保存失败。"
                }
                completion?(true)
            }
        }
    }
}
