import AppKit
import SwiftUI

// MARK: - Theme

/// Shared metrics and colours of the Ports rows (ported from PortPilot's panel). Accent colours are used sparingly:
/// orange = auto-restart, red = destructive (hover only), purple/blue = origin badges, yellow = heavy usage.
enum PortTheme {
    static let iconSize: CGFloat = 28
    static let chevronWidth: CGFloat = 12
    /// Leading offset of a group row's text column (chevron + icon + gaps); nested content aligns to it.
    static let textColumnInset: CGFloat = chevronWidth + 8 + iconSize + 10

    static let autoRestart = Color.orange
    static let destructive = Color.red
    static let agentOrigin = Color.purple
    static let toolOrigin = Color.blue
    /// Yellow that stays legible on light backgrounds (systemYellow is too pale on white).
    static let heavy = Color(nsColor: NSColor(name: NSColor.Name("MacCleaner.network.heavy")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.systemYellow
            : NSColor(srgbRed: 0.72, green: 0.52, blue: 0.0, alpha: 1)
    })

    static let hoverFill = Color.primary.opacity(0.05)
    static let pressedFill = Color.primary.opacity(0.10)
    static let chipFill = Color.primary.opacity(0.07)
    static let insetFill = Color.primary.opacity(0.04)

    static let command = Font.system(size: 11, design: .monospaced)
    static let metric = Font.system(size: 11).monospacedDigit()
}

// MARK: - Buttons

/// Plain button with a rounded highlight on hover/press, like the toolbar buttons of first-party utilities.
struct PortHoverButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 6
    var padding = EdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 7)
    /// Resting foreground; nil inherits the surrounding style.
    var foreground: AnyShapeStyle? = nil
    /// Foreground + tinted highlight while hovered (e.g. red for destructive buttons). nil = neutral highlight.
    var hoverTint: Color? = nil
    /// Keeps the tinted highlight on without hovering (an armed confirm button).
    var isEmphasized = false

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, style: self)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyleConfiguration
        let style: PortHoverButtonStyle
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
            configuration.label
                .padding(style.padding)
                .modifier(PortOptionalForeground(style: currentForeground))
                .background(shape.fill(background))
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }

        private var isHighlighted: Bool { isEnabled && (isHovering || configuration.isPressed) }

        private var currentForeground: AnyShapeStyle? {
            if let tint = style.hoverTint, isHighlighted || style.isEmphasized { return AnyShapeStyle(tint) }
            return style.foreground
        }

        private var background: Color {
            if let tint = style.hoverTint, style.isEmphasized {
                return tint.opacity(configuration.isPressed ? 0.26 : isHovering ? 0.2 : 0.14)
            }
            if style.isEmphasized { return configuration.isPressed ? PortTheme.pressedFill : Color.primary.opacity(0.09) }
            guard isHighlighted else { return .clear }
            if let tint = style.hoverTint { return tint.opacity(configuration.isPressed ? 0.2 : 0.12) }
            return configuration.isPressed ? PortTheme.pressedFill : PortTheme.hoverFill
        }
    }
}

/// Applies a foreground style only when one is given, so labels keep their inherited colour otherwise.
private struct PortOptionalForeground: ViewModifier {
    let style: AnyShapeStyle?

    func body(content: Content) -> some View {
        if let style { content.foregroundStyle(style) } else { content }
    }
}

/// Square icon-only button with tooltip and accessibility label.
struct PortIconButton: View {
    let systemImage: String
    let label: String
    var help: String? = nil
    var size: CGFloat = 13
    var foreground: AnyShapeStyle? = AnyShapeStyle(.secondary)
    var hoverTint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(PortHoverButtonStyle(padding: EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2),
                                          foreground: foreground, hoverTint: hoverTint))
        .help(help ?? label)
        .accessibilityLabel(label)
    }
}

/// Click logic of `PortConfirmButton`, free of UI so it can be unit tested.
///
/// The first click arms. A later click confirms only once the system double-click interval has passed since
/// arming, and never as the second click of a double-click: SwiftUI fires a Button on every mouse-up, so without
/// this guard a habitual double-click would arm *and* confirm before "Stop?" is even drawn.
struct PortConfirmGate: Equatable {
    enum Outcome: Equatable {
        case armed
        /// Too soon after arming (or part of a double-click): stays armed, nothing runs.
        case ignored
        case confirmed
    }

    private(set) var armedAt: Date?
    var isArmed: Bool { armedAt != nil }

    mutating func click(at now: Date, clickCount: Int = 1, doubleClickInterval: TimeInterval) -> Outcome {
        guard let armedAt else {
            self.armedAt = now
            return .armed
        }
        if clickCount > 1 || now.timeIntervalSince(armedAt) < doubleClickInterval {
            return .ignored
        }
        self.armedAt = nil
        return .confirmed
    }

    mutating func disarm() {
        armedAt = nil
    }

    /// Click count of the event being handled; 1 for anything that isn't a mouse click.
    @MainActor
    static var currentClickCount: Int {
        guard let event = NSApp?.currentEvent else { return 1 }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return event.clickCount
        default:
            return 1
        }
    }
}

/// Inline two-step confirmation for stopping apps, macOS services and other users' processes: the first click arms
/// the button for `timeout`, a second click runs `action` (see `PortConfirmGate`). Works inside the menu bar
/// popover, where an alert would close it. With an empty `title` it rests as an icon-only button.
struct PortConfirmButton: View {
    let title: String
    var confirmTitle = "Confirm"
    var systemImage: String? = nil
    var tint: Color = PortTheme.destructive
    var foreground: AnyShapeStyle? = nil
    var timeout: Duration = .seconds(3)
    var font: Font = .system(size: 12, weight: .medium)
    var help: String? = nil
    /// Tooltip while armed: say what the second click will do.
    var armedHelp = "Click again to confirm"
    var accessibilityName: String? = nil
    var iconSize: CGFloat = 13
    /// Receives the modifier flags of the confirming click (⌥ = force).
    let action: (NSEvent.ModifierFlags) -> Void

    @State private var gate = PortConfirmGate()
    @State private var disarmTask: Task<Void, Never>?

    private var isArmed: Bool { gate.isArmed }
    private var isIconOnly: Bool { title.isEmpty && systemImage != nil }

    var body: some View {
        Button(action: handleClick) {
            if isIconOnly && !isArmed, let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: iconSize, weight: .medium))
                    .frame(width: 18, height: 18)
            } else {
                HStack(spacing: 5) {
                    if let systemImage {
                        Image(systemName: isArmed ? "exclamationmark.circle.fill" : systemImage)
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    Text(isArmed ? confirmTitle : title)
                        .lineLimit(1)
                }
                .font(font)
            }
        }
        .buttonStyle(PortHoverButtonStyle(
            padding: isIconOnly && !isArmed ? EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)
                                            : EdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 7),
            foreground: foreground, hoverTint: tint, isEmphasized: isArmed))
        .help(isArmed ? armedHelp : (help ?? title))
        .accessibilityLabel(isArmed ? confirmTitle : (accessibilityName ?? title))
        .accessibilityHint(isArmed ? armedHelp : "Asks to confirm first")
        .onDisappear { disarm() }
    }

    private func handleClick() {
        var gate = self.gate
        let outcome = gate.click(at: Date(), clickCount: PortConfirmGate.currentClickCount,
                                 doubleClickInterval: NSEvent.doubleClickInterval)
        switch outcome {
        case .armed:
            withAnimation(.easeOut(duration: 0.15)) { self.gate = gate }
            scheduleDisarm()
        case .ignored:
            break
        case .confirmed:
            disarm()
            action(NSEvent.modifierFlags)
        }
    }

    private func scheduleDisarm() {
        disarmTask?.cancel()
        disarmTask = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { gate.disarm() }
        }
    }

    private func disarm() {
        disarmTask?.cancel()
        disarmTask = nil
        gate.disarm()
    }
}

// MARK: - Stop control

/// The Stop control of a row: one click for projects and services, two clicks for apps, macOS services and other
/// users' processes (`PortStopSafety`), nothing for launchd itself. ⌥ on the (final) click force-stops.
struct PortStopControl: View {
    let title: String
    let safety: PortStopSafety
    let isBusy: Bool
    var size: CGFloat = 15
    let stop: (PortStopMode) -> Void

    var body: some View {
        if isBusy {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.75)
                .frame(width: 22, height: 22)
                .accessibilityLabel("Stopping \(title)")
        } else {
            switch safety {
            case .unavailable:
                Color.clear
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
            case .oneClick:
                PortIconButton(systemImage: "xmark.circle.fill", label: "Stop \(title)",
                               help: "Stop \(title) — ⌥-click to force stop", size: size,
                               foreground: AnyShapeStyle(.tertiary), hoverTint: PortTheme.destructive) {
                    stop(NSEvent.modifierFlags.contains(.option) ? .force : .graceful)
                }
            case .confirm(let reason):
                PortConfirmButton(title: "", confirmTitle: "Stop?", systemImage: "xmark.circle.fill",
                                  foreground: AnyShapeStyle(.tertiary),
                                  help: "Stop \(title) (asks to confirm) — ⌥-click to force stop",
                                  armedHelp: reason.armedHelp(title: title),
                                  accessibilityName: "Stop \(title)", iconSize: size) { flags in
                    stop(flags.contains(.option) ? .force : .graceful)
                }
                .fixedSize()
            }
        }
    }
}

// MARK: - Port chips

/// Clickable ":PORT" chip → opens http://localhost:PORT. Its context menu copies the URL or port.
struct PortChipButton: View {
    let port: UInt16
    var isExposed = false
    var compact = false
    let open: (UInt16) -> Void
    let copy: (String) -> Void

    @State private var isHovering = false

    private var url: String { "http://localhost:\(port)" }

    var body: some View {
        Button {
            open(port)
        } label: {
            HStack(spacing: 3) {
                if isExposed {
                    Image(systemName: "globe")
                        .font(.system(size: compact ? 8.5 : 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: ":\(port)")
                    .font(.system(size: compact ? 11 : 12, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(isHovering ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary.opacity(0.85)))
            .padding(.horizontal, compact ? 5 : 7)
            .padding(.vertical, compact ? 1.5 : 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHovering ? Color.accentColor.opacity(0.15) : PortTheme.chipFill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHovering = $0 }
        .help(isExposed ? "Open \(url) — listening on all interfaces, so other devices on your network can reach it"
                        : "Open \(url)")
        .accessibilityLabel("Port \(String(port))")
        .accessibilityHint("Opens \(url) in your browser")
        .contextMenu {
            Button("Open in Browser") { open(port) }
            Divider()
            Button("Copy URL") { copy(url) }
            Button("Copy Port") { copy(String(port)) }
        }
    }
}

/// How many port chips a row shows before the rest collapse into "+N". Pure, so it is unit tested.
enum PortChipOverflow {
    static let defaultLimit = 3

    /// Up to `limit` ports show as chips; with more, the last slot becomes "+N"
    /// (limit 3: [a, b, c] → a b c, [a, b, c, d] → a b +2).
    static func split(_ ports: [UInt16], limit: Int = defaultLimit) -> (shown: [UInt16], hidden: [UInt16]) {
        let limit = max(1, limit)
        let shownCount = ports.count > limit ? limit - 1 : ports.count
        return (Array(ports.prefix(shownCount)), Array(ports.dropFirst(shownCount)))
    }

    /// ":3000  :3001" for tooltips.
    static func list(_ ports: [UInt16]) -> String {
        ports.map { ":\($0)" }.joined(separator: "  ")
    }
}

/// A row's port chips, capped so any number of ports takes bounded width.
struct PortChips: View {
    let ports: [UInt16]
    var exposedPorts: Set<UInt16> = []
    var limit = PortChipOverflow.defaultLimit
    var compact = false
    let open: (UInt16) -> Void
    let copy: (String) -> Void

    var body: some View {
        let split = PortChipOverflow.split(ports, limit: limit)
        HStack(spacing: compact ? 3 : 4) {
            ForEach(split.shown, id: \.self) { port in
                PortChipButton(port: port, isExposed: exposedPorts.contains(port), compact: compact, open: open, copy: copy)
            }
            if !split.hidden.isEmpty {
                Menu {
                    ForEach(split.hidden, id: \.self) { port in
                        Button("Open localhost:\(String(port))") { open(port) }
                    }
                    Divider()
                    Button(split.hidden.count == 1 ? "Copy Port" : "Copy Ports") {
                        copy(split.hidden.map { String($0) }.joined(separator: " "))
                    }
                } label: {
                    Text(verbatim: "+\(split.hidden.count)")
                        .font(.system(size: compact ? 11 : 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, compact ? 4 : 6)
                        .padding(.vertical, compact ? 1.5 : 3)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(PortTheme.chipFill))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Also listening on " + PortChipOverflow.list(split.hidden))
                .accessibilityLabel("\(split.hidden.count) more ports")
            }
        }
        .fixedSize()
    }
}

// MARK: - Usage

/// "3.2% · 412 MB" with monospaced digits; a yellow pill when a metric crosses its threshold.
struct PortUsagePill: View {
    let usage: PortResourceUsage
    var compact = false

    private var cpuIsHeavy: Bool { usage.cpuPercent >= NetworkPreferences.heavyCPUThreshold }
    private var memoryIsHeavy: Bool { usage.memoryBytes >= NetworkPreferences.heavyMemoryBytes }
    private var isHeavy: Bool { cpuIsHeavy || memoryIsHeavy }

    var body: some View {
        HStack(spacing: 4) {
            if isHeavy {
                Image(systemName: "flame.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PortTheme.heavy)
            }
            Text(PortFormat.cpu(usage.cpuPercent))
                .foregroundStyle(cpuIsHeavy ? AnyShapeStyle(PortTheme.heavy) : AnyShapeStyle(.secondary))
            Text(verbatim: "·")
                .foregroundStyle(.tertiary)
            Text(PortFormat.bytes(usage.memoryBytes))
                .foregroundStyle(memoryIsHeavy ? AnyShapeStyle(PortTheme.heavy) : AnyShapeStyle(.secondary))
        }
        .font(isHeavy ? .system(size: compact ? 10.5 : 11, weight: .semibold).monospacedDigit()
                      : .system(size: compact ? 10.5 : 11).monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, isHeavy ? 6 : 0)
        .padding(.vertical, isHeavy ? 1.5 : 0)
        .background {
            if isHeavy { Capsule(style: .continuous).fill(PortTheme.heavy.opacity(0.16)) }
        }
        .fixedSize()
        .help(isHeavy ? "Heavy: CPU \(PortFormat.cpu(usage.cpuPercent)) of one core, memory \(PortFormat.bytes(usage.memoryBytes))"
                      : "CPU (% of one core) · memory, including child processes")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU \(PortFormat.cpu(usage.cpuPercent)), memory \(PortFormat.bytes(usage.memoryBytes))\(isHeavy ? ", heavy" : "")")
    }
}

/// Disclosure chevron that rotates when expanded.
struct PortDisclosureChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
    }
}

/// Self-updating relative time ("4m ago").
struct PortTimeAgoText: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 5)) { context in
            Text(Self.format(context.date.timeIntervalSince(date)))
        }
    }

    nonisolated static func format(_ elapsed: TimeInterval) -> String {
        if elapsed < 5 { return "just now" }
        return PortFormat.uptime(since: Date(timeIntervalSinceNow: -elapsed)) + " ago"
    }
}

// MARK: - Layout

/// Left-aligned wrapping layout for badge rows (wraps instead of clipping when a row is crowded).
struct PortFlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(maxWidth: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(maxWidth: bounds.width, subviews: subviews)
        for (index, frame) in arrangement.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        frames.reserveCapacity(subviews.count)
        var lineStart = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        func finishLine(upTo end: Int) {
            for index in lineStart..<end {
                frames[index].origin.y = y + (lineHeight - frames[index].height) / 2
            }
        }

        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            if maxWidth.isFinite { size.width = min(size.width, maxWidth) }
            if x > 0, x + size.width > maxWidth {
                finishLine(upTo: index)
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
                lineStart = index
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        finishLine(upTo: frames.count)
        let height = frames.isEmpty ? 0 : y + lineHeight
        return (CGSize(width: usedWidth, height: height), frames)
    }
}

// MARK: - Icons

/// Leading icon of a group row: the real app icon for apps, otherwise a tinted SF Symbol tile.
struct PortGroupIcon: View {
    let group: PortListenerGroup
    var size: CGFloat = PortTheme.iconSize

    var body: some View {
        Group {
            if group.category == .app, let path = group.path, path.hasSuffix(".app") {
                FileIcon(path: path, size: size + 2)
                    .padding(-1)
            } else {
                let tint = Self.tint(for: group.category)
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(tint.opacity(0.15))
                    .overlay(
                        Image(systemName: Self.symbol(for: group))
                            .font(.system(size: size * 0.46, weight: .semibold))
                            .foregroundStyle(tint))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    static func tint(for category: PortListenerCategory) -> Color {
        switch category {
        case .project: return .blue
        case .service: return .teal
        case .app: return .indigo
        case .system: return .gray
        }
    }

    /// Picks a symbol from the detected frameworks, falling back to the category.
    static func symbol(for group: PortListenerGroup) -> String {
        let names = group.frameworks.map { $0.lowercased() }
        func has(_ needles: String...) -> Bool {
            names.contains { name in needles.contains { name.contains($0) } }
        }
        if has("postgres", "mysql", "mongo", "redis", "sqlite", "mariadb") { return "cylinder.split.1x2" }
        if has("cloudflared", "ngrok", "tailscale", "tunnel") { return "point.3.filled.connected.trianglepath.dotted" }
        if has("nginx", "caddy", "traefik") { return "arrow.triangle.branch" }
        if has("ollama") { return "brain" }
        if has("jupyter") { return "book.closed" }
        if has("docker") { return "shippingbox" }
        if has("vite", "next", "nuxt", "astro", "remix", "svelte", "webpack", "parcel", "storybook", "angular",
               "expo", "metro", "hugo", "jekyll") { return "macwindow" }
        if has("uvicorn", "gunicorn", "fastapi", "flask", "django", "express", "nest", "rails", "puma", "php",
               "laravel", "streamlit", "gradio", "spring", "java", ".net", "go", "rust", "bun", "deno", "http.server") {
            return "server.rack"
        }
        switch group.category {
        case .project: return "chevron.left.forwardslash.chevron.right"
        case .service: return "gearshape.2"
        case .app: return "app"
        case .system: return "gearshape"
        }
    }
}

// MARK: - Badge helpers

extension PortLaunchOrigin {
    /// Purple for AI agents, blue for IDEs/terminals, neutral for supervisors.
    var badgeTint: Color {
        switch kind {
        case .claudeCode, .codex, .aiAgent: return PortTheme.agentOrigin
        case .ide, .terminal, .shell: return PortTheme.toolOrigin
        case .launchd, .pm2, .docker, .app, .unknown: return .gray
        }
    }

    var badgeSymbol: String {
        switch kind {
        case .claudeCode, .codex, .aiAgent: return "sparkles"
        case .ide: return "chevron.left.forwardslash.chevron.right"
        case .terminal, .shell: return "terminal"
        case .launchd: return "gearshape"
        case .pm2: return "arrow.triangle.2.circlepath"
        case .docker: return "shippingbox"
        case .app: return "app"
        case .unknown: return "questionmark"
        }
    }
}

extension PortListenerGroup {
    /// The manager that will bring this group back after a plain stop (launchd KeepAlive/RunAtLoad, pm2, Docker).
    var autoRestartManager: PortProcessManager? {
        processes.lazy.map(\.manager).first { $0.isAutoRestarting }
    }

    /// Manager shown as the row's badge: an auto-restarting one first, else any non-watcher supervisor.
    var supervisingManager: PortProcessManager? {
        autoRestartManager ?? processes.lazy.map(\.manager).first { $0 != .none && !$0.isWatcher }
    }

    var exposedPorts: Set<UInt16> {
        Set(processes.flatMap { $0.sockets.filter(\.isExposed).map(\.port) })
    }

    /// The launchd label of a launchd-managed group (its full name, for tooltips and search).
    var launchdLabel: String? {
        processes.lazy.compactMap { process -> String? in
            if case .launchd(let job) = process.manager { return job.label }
            return nil
        }.first
    }

    /// Folder to show/reveal: the group's path, else the executable (services without a project folder).
    var locationPath: String? {
        if let path, !path.isEmpty, path != "/" { return path }
        if let executable = processes.first?.details?.executablePath, executable.hasPrefix("/") { return executable }
        return nil
    }
}

extension PortProcessManager {
    var isWatcher: Bool {
        if case .watcher = self { return true }
        return false
    }

    /// "launchd · auto-start" / "brew services · auto-start" / "nodemon".
    var badgeText: String? {
        guard let badge else { return nil }
        return isAutoRestarting ? "\(badge) · auto-start" : badge
    }

    var badgeSymbol: String {
        switch self {
        case .none: return "circle"
        case .launchd, .pm2, .docker: return isAutoRestarting ? "arrow.clockwise" : "gearshape"
        case .watcher: return "eye"
        }
    }

    /// One-line explanation of what restarts it.
    var autoRestartExplanation: String? {
        switch self {
        case .launchd(let job):
            if job.keepAlive { return "launchd restarts this automatically (KeepAlive)." }
            if job.runAtLoad { return "launchd starts this again at every login." }
            return nil
        case .pm2(_, let name): return "pm2 restarts “\(name)” automatically."
        case .docker(let container):
            return "Docker restarts “\(container.name)” (restart policy: \(container.restartPolicy ?? "unknown"))."
        case .none, .watcher: return nil
        }
    }
}

/// A badge for a group row, built from the scan.
struct PortBadgeModel: Identifiable, Hashable {
    var id: String { text }
    let text: String
    var symbol: String? = nil
    var tint: Color = .gray
    var help: String? = nil

    /// Frameworks, origin ("Claude Code", "Terminal"), supervising manager ("launchd · auto-start") and "Network".
    static func badges(for group: PortListenerGroup, frameworkLimit: Int = 3) -> [PortBadgeModel] {
        var result: [PortBadgeModel] = group.frameworks.prefix(frameworkLimit).map { PortBadgeModel(text: $0) }
        // Skip origins that only repeat what the row already says (an app launched itself; launchd shown as manager).
        if let origin = group.origin, origin.kind != .app,
           origin.kind != .launchd || group.supervisingManager == nil {
            result.append(PortBadgeModel(text: origin.name, symbol: origin.badgeSymbol, tint: origin.badgeTint,
                                         help: "Started from \(origin.name)"))
        }
        if let manager = group.supervisingManager, let text = manager.badgeText {
            result.append(PortBadgeModel(text: text, symbol: manager.badgeSymbol,
                                         tint: manager.isAutoRestarting ? PortTheme.autoRestart : .gray,
                                         help: manager.autoRestartExplanation ?? "Supervised by \(text)"))
        }
        if group.isExposedToNetwork {
            result.append(PortBadgeModel(text: "Network", symbol: "globe", tint: .gray,
                                         help: "Listening on all interfaces — reachable from other devices on your network"))
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.text).inserted }
    }

    static func == (lhs: PortBadgeModel, rhs: PortBadgeModel) -> Bool { lhs.text == rhs.text && lhs.help == rhs.help }
    func hash(into hasher: inout Hasher) { hasher.combine(text) }
}

// MARK: - Window visibility

/// Reports whether the hosting window is on screen. A MenuBarExtra(.window) keeps its content alive between
/// openings (onAppear/onDisappear are unreliable there), so this watches the NSWindow's occlusion and key state.
/// Becoming key counts as visible: it is posted while the popover opens, before the occlusion notification.
struct PortWindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onChange = onChange
    }

    static func dismantleNSView(_ nsView: ObserverView, coordinator: ()) {
        nsView.detach()
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            guard let window else {
                send(false)
                return
            }
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didResignKeyNotification] {
                tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            tokens.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.send(false) }
            })
            report()
        }

        /// Called when SwiftUI removes the view: it no longer shows anything.
        func detach() {
            removeObservers()
            send(false)
        }

        private func report() {
            guard let window else { return }
            send(Self.isOnScreen(isVisible: window.isVisible, isKey: window.isKeyWindow,
                                 occlusionVisible: window.occlusionState.contains(.visible)))
        }

        private func send(_ visible: Bool) {
            guard visible != lastReported else { return }
            lastReported = visible
            onChange?(visible)
        }

        /// Ordered in, and either reported visible by the window server or key (the popover is opening).
        nonisolated static func isOnScreen(isVisible: Bool, isKey: Bool, occlusionVisible: Bool) -> Bool {
            isVisible && (occlusionVisible || isKey)
        }

        private func removeObservers() {
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens.removeAll()
        }
    }
}

// MARK: - Banner

/// Feedback after an action, with an optional action button and ×.
struct PortBannerView: View {
    let banner: PortBanner
    var onAction: (() -> Void)?
    let onDismiss: () -> Void

    private var style: InfoCallout.Style {
        switch banner.style {
        case .info: return .info
        case .success: return .success
        case .warning: return .warning
        case .error: return .danger
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: style.symbol)
                .foregroundStyle(style.tint)
                .font(.system(size: 15))
            Text(banner.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if let title = banner.actionTitle, let onAction {
                Button(title, action: onAction)
                    .controlSize(.small)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(style.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(style.tint.opacity(0.18)))
    }
}
