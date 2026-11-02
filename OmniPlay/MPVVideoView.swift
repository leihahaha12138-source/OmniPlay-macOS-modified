import SwiftUI
import AppKit
import QuartzCore
import Libmpv

private final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            // MoltenVK can briefly force 1x1 during resize; ignoring that keeps mpv's
            // render target from getting stuck at a stale tiny size.
            guard newValue.width > 1, newValue.height > 1 else { return }
            super.drawableSize = newValue
        }
    }
}

private final class MPVContainerView: NSView {
    weak var playerManager: MPVPlayerManager?
    private var lastLayoutSize: CGSize = .zero
    private var windowObservationTokens: [NSObjectProtocol] = []
    /// 重建 VO 的防抖句柄：手动拖拽窗口会连发几十次 didResize，需合并成一次重建。
    private var voRebuildWorkItem: DispatchWorkItem?
    /// 标记「刚安排了一次全屏切换重建」，用于让紧随其后的 didResize 不再重复触发。
    private var pendingFullscreenRebuild = false
    private var isLiveResizing = false
    private var autoPausedForLiveResize = false
    private var resumeAfterLiveResizeWorkItem: DispatchWorkItem?

    deinit {
        resumeAfterLiveResizeWorkItem?.cancel()
        voRebuildWorkItem?.cancel()
        removeWindowObservers()
    }

    override func layout() {
        super.layout()
        handleGeometryChange(rebuildLayer: false)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        handleGeometryChange(rebuildLayer: false)
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        handleGeometryChange(rebuildLayer: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        scheduleDrawableRefresh(delays: [0.0, 0.05], rebind: true)
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        beginLiveResize()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        endLiveResize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installWindowObservers()
        scheduleDrawableRefresh(delays: [0.0, 0.12], rebind: true)
    }

    func ensureMetalLayer(rebind: Bool) {
        let metalLayer: CAMetalLayer
        if let existingLayer = layer as? CAMetalLayer {
            metalLayer = existingLayer
        } else {
            metalLayer = MPVMetalLayer()
            layer = metalLayer
        }
        configure(metalLayer)
        lastLayoutSize = bounds.size
        if rebind {
            playerManager?.setDrawable(self, force: true)
        }
    }

    private func installWindowObservers() {
        removeWindowObservers()
        guard let window else { return }
        let center = NotificationCenter.default
        let events: [(Notification.Name, [TimeInterval], Bool)] = [
            (NSWindow.didResizeNotification, [0.0, 0.016, 0.05], false),
            (NSWindow.didEnterFullScreenNotification, [0.0, 0.08, 0.22, 0.45], true),
            (NSWindow.didExitFullScreenNotification, [0.0, 0.08, 0.22, 0.45, 0.8], true)
        ]
        windowObservationTokens = events.map { eventName, delays, shouldRebind in
            center.addObserver(forName: eventName, object: window, queue: .main) { [weak self] _ in
                guard let self else { return }
                DiagLog.write("窗口", "收到 \(eventName.rawValue) bounds=\(String(describing: self.bounds.size)) 将延迟重绑=\(shouldRebind || self.autoPausedForLiveResize) 延迟列表=\(delays)")
                self.scheduleDrawableRefresh(delays: delays, rebind: shouldRebind || self.autoPausedForLiveResize)
                // 窗口尺寸变了但 mpv 的 MoltenVK 输出仍按旧尺寸绘制 → 画面裁切。
                // 唯一可靠的同步方式是重建视频输出（vid=no → vid=auto），官方 demo 用同样做法
                // 修前后台切换后的黑屏。实测：重建后 mpv 的 osd-width/height 会立刻跟上 layer。
                //
                // 三种场景都要覆盖（否则会漏）：
                //   · 退出全屏 → 由小变大，需要重建
                //   · 进入全屏 → 由小变大，同样需要（漏了这个只会显示中间一小块）
                //   · 手动拖拽窗口 → 持续变化，等拖拽结束后（debounce）再重建一次
                // 全屏切换：目标尺寸是确定的（小窗 1200x760 / 全屏铺满），
                //   短延迟即可，不必等防抖窗口结束 → 画面恢复更快。
                // 手动拖拽：尺寸连续变化且事先未知，必须等稳定 → 用较长防抖。
                switch eventName {
                case NSWindow.didExitFullScreenNotification:
                    self.scheduleVORebuild(after: 0.15, reason: "退出全屏", isFullscreen: true)
                case NSWindow.didEnterFullScreenNotification:
                    self.scheduleVORebuild(after: 0.15, reason: "进入全屏", isFullscreen: true)
                case NSWindow.didResizeNotification:
                    // 若刚发生过全屏切换，则本次 resize 是它的后续事件，
                    // 交给上面那次短延迟的重建处理，这里跳过以免二次重建。
                    if !self.pendingFullscreenRebuild {
                        self.scheduleVORebuild(after: 0.6, reason: "手动改尺寸")
                    }
                default:
                    break
                }
            }
        }
        let liveResizeTokens: [NSObjectProtocol] = [
            center.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                self?.beginLiveResize()
            },
            center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                self?.endLiveResize()
            }
        ]
        windowObservationTokens.append(contentsOf: liveResizeTokens)
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        for token in windowObservationTokens {
            center.removeObserver(token)
        }
        windowObservationTokens = []
    }

    private func configure(_ metalLayer: CAMetalLayer) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let pointSize = bounds.size
        let drawableSize = NSSize(
            width: pointSize.width * scale,
            height: pointSize.height * scale
        )
        // 每次 configure 都记录（含读回值）。drawableSize 是重写的属性，
        // 若被 set 拒绝（<=1 会被忽略）读回值会与写入值不同，这本身就是要观察的信号。
        DiagLog.write("渲染层", String(
            format: "configure 写入 drawable=%.0fx%.0f points=%.0fx%.0f scale=%.2f",
            drawableSize.width, drawableSize.height,
            pointSize.width, pointSize.height, scale
        ))
        metalLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull(),
            "contentsScale": NSNull(),
            "drawableSize": NSNull()
        ]
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.frame = CGRect(origin: .zero, size: pointSize)
        // 这一段必须保留：mpv 走 MoltenVK，直接把该 layer 当渲染目标
        // （vo_thread -> gpu_ctx_create -> moltenvk_init -> MVKSurface::initLayer(CAMetalLayer*)），
        // 所以 layer 的 drawableSize 必须与窗口一致，否则画面按旧尺寸绘制而被裁切。
        metalLayer.contentsScale = scale
        if drawableSize.width > 1, drawableSize.height > 1 {
            metalLayer.drawableSize = drawableSize
        }
        metalLayer.presentsWithTransaction = false
        metalLayer.allowsNextDrawableTimeout = false
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.masksToBounds = true
        metalLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // ★ 关键修复：contentsGravity 用 .resizeAspect（Core Animation 负责按比例缩放整个
        // 渲染目标），而不是 .resize（拉伸填满）。
        //
        // 背景（2026-10-02 实测 + MPVKit 官方 issue #3 确认）：
        // MoltenVK 只在**视频加载那一刻**读一次 layer 尺寸，之后不再感知 resize ——
        //   "the moltenvk context only picks up the layer size when a video loads
        //    and never gets told about resizes afterwards"
        // 于是从全屏退回小窗时：layer 已缩到 2400x1520，但 mpv 仍按全屏 2940x1846 绘制，
        // 画面只露出左上角一块（2400/2940 ≈ 0.816，正是你看到的「只剩全屏的几分之一」）。
        //
        // .resizeAspect 让 Core Animation 在 layer 尺寸变化时对已渲染内容等比缩放，
        // 因此即使 mpv 内部尺寸没更新，画面也能完整显示（小窗内自动加黑边）。
        // 这是 issue #3 中 @alexiscn 给出并验证过的做法。
        metalLayer.contentsGravity = .resizeAspect
        metalLayer.needsDisplayOnBoundsChange = true
        metalLayer.setNeedsDisplay()
        // 读回实际生效值：若与写入值不符说明被拒收了（MVPMetalLayer 会忽略 <=1 的尺寸）
        let actual = metalLayer.drawableSize
        if actual != drawableSize {
            DiagLog.write("渲染层", String(
                format: "★ drawableSize 被拒：写入 %.0fx%.0f → 实际 %.0fx%.0f",
                drawableSize.width, drawableSize.height, actual.width, actual.height
            ))
        }
    }

    private func handleGeometryChange(rebuildLayer: Bool) {
        refreshDrawableSize()

        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if rebuildLayer || size != lastLayoutSize {
            lastLayoutSize = size
            let delays: [TimeInterval] = isLiveResizing ? [0.0, 0.016] : [0.0, 0.05]
            scheduleDrawableRefresh(
                delays: rebuildLayer ? [0.0, 0.08, 0.22, 0.45] : delays,
                rebind: rebuildLayer || autoPausedForLiveResize
            )
        }
    }

    private func beginLiveResize() {
        resumeAfterLiveResizeWorkItem?.cancel()
        resumeAfterLiveResizeWorkItem = nil
        isLiveResizing = true
        if !autoPausedForLiveResize, playerManager?.isPlaying == true {
            autoPausedForLiveResize = true
            playerManager?.setPaused(true)
        }
        scheduleDrawableRefresh(delays: [0.0, 0.016, 0.033], rebind: autoPausedForLiveResize)
    }

    private func endLiveResize() {
        isLiveResizing = false
        scheduleDrawableRefresh(delays: [0.0, 0.08, 0.22, 0.45], rebind: true)
        resumeAfterLiveResizeIfNeeded()
    }

    private func resumeAfterLiveResizeIfNeeded() {
        guard autoPausedForLiveResize else { return }
        resumeAfterLiveResizeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.window != nil, self.autoPausedForLiveResize else { return }
            self.refreshDrawable(rebind: true)
            self.playerManager?.setPaused(false)
            self.autoPausedForLiveResize = false
            self.resumeAfterLiveResizeWorkItem = nil
        }
        resumeAfterLiveResizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    func refreshDrawable(rebind: Bool) {
        refreshDrawableSize()
        if rebind {
            playerManager?.setDrawable(self, force: true)
        }
    }

    private func refreshDrawableSize() {
        if let metalLayer = layer as? CAMetalLayer {
            configure(metalLayer)
        } else {
            ensureMetalLayer(rebind: false)
        }
    }

    /// 延时重建视频输出，连续调用会互相覆盖（防抖）。
    ///
    /// 手动拖拽窗口时 didResize 会连发几十次，若每次都重建 VO 会明显卡顿并频繁黑屏，
    /// 因此用 workItem 覆盖式延后：只有最后一次调用会真正执行。
    private func scheduleVORebuild(after delay: TimeInterval, reason: String, isFullscreen: Bool = false) {
        voRebuildWorkItem?.cancel()
        // 全屏切换的标记覆盖「延迟 + 0.4s」这段时间，其间的 didResize 都跳过。
        pendingFullscreenRebuild = isFullscreen
        let item = DispatchWorkItem { [weak self] in
            guard let self, let pm = self.playerManager else { return }
            DiagLog.write("渲染层", "触发 VO 重建（\(reason)）")
            pm.rebuildVideoOutputForResize()
        }
        voRebuildWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        if isFullscreen {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.4) { [weak self] in
                self?.pendingFullscreenRebuild = false
            }
        }
    }

    private func scheduleDrawableRefresh(delays: [TimeInterval], rebind: Bool) {
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.window != nil else { return }
                self.layoutSubtreeIfNeeded()
                self.refreshDrawable(rebind: rebind)
            }
        }
    }
}

struct MPVVideoView: NSViewRepresentable {
    let playerManager: MPVPlayerManager

    final class Coordinator {
        var lastSize: CGSize = .zero
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = MPVContainerView(frame: .zero)
        view.playerManager = playerManager
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        view.layerContentsRedrawPolicy = .duringViewResize

        view.ensureMetalLayer(rebind: false)
        context.coordinator.lastSize = view.bounds.size

        print("[MPVVideoView] makeNSView created")
        // Bind immediately so PlayerScreen can wait for drawable-ready before loadFiles.
        playerManager.setDrawable(view)

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let newSize = nsView.bounds.size
        if newSize != context.coordinator.lastSize {
            context.coordinator.lastSize = newSize
            if let videoView = nsView as? MPVContainerView {
                videoView.refreshDrawable(rebind: false)
            }
        }
    }
}
