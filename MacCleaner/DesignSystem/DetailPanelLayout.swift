import SwiftUI

/// Content with a details panel on its trailing side, there only while `isPresented`.
///
/// Pure SwiftUI on purpose, like `DuplicateSplitView`. SwiftUI's `.inspector` adds a
/// column to the window's split view, and that column takes its minimum width from the
/// page, plus the sidebar's safe-area inset counted twice. When that is more than the
/// window has (a page with a wide table at the window's minimum size), the column's frame
/// and its safe-area insets change each other on every layout pass, until AppKit stops
/// the window with an exception. Here the panel is part of the page: its width simply
/// adds to the page's minimum width, which the window's minimum size accounts for.
struct DetailPanelLayout<Content: View, Panel: View>: View {
    var isPresented: Bool
    var panelWidth: CGFloat
    @ViewBuilder var content: () -> Content
    @ViewBuilder var panel: () -> Panel

    init(
        isPresented: Bool,
        panelWidth: CGFloat = 330,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder panel: @escaping () -> Panel
    ) {
        self.isPresented = isPresented
        self.panelWidth = panelWidth
        self.content = content
        self.panel = panel
    }

    var body: some View {
        HStack(spacing: 0) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if isPresented {
                Divider()
                panel()
                    .frame(width: panelWidth)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isPresented)
    }
}
