import AppKit
import SwiftUI
import Testing
@testable import MacCleaner

/// Measures views offscreen the way a split view column measures its content.
@MainActor
enum LayoutProbe {
    /// The size SwiftUI reports for a zero proposal, which `NavigationSplitView` uses as a
    /// column's minimum size.
    static func minimumSize<V: View>(_ view: V) -> CGSize {
        NSHostingController(rootView: view).sizeThatFits(in: .zero)
    }

    static func size<V: View>(_ view: V, width: CGFloat) -> CGSize {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 0))
    }

    static func services() throws -> AppServices {
        let defaults = try #require(UserDefaults(suiteName: "PageMinimumSizeTests-\(UUID().uuidString)"))
        return AppServices(settings: SettingsManager(defaults: defaults))
    }

    /// The smallest page the window gives: 1000 × 660 points of content, less the
    /// sidebar (up to 300 points wide) and the toolbar (52 points).
    static let smallestPage = CGSize(width: 700, height: 608)
}

/// A page's minimum size must fit the smallest window. A column whose content measured
/// taller than the window was sized past the window's edge by AppKit; its toolbar inset
/// then changed with that frame and changed the minimum again on every layout pass, until
/// AppKit stopped the window with an exception (the crash on the Uninstaller page).
@MainActor
struct PageMinimumSizeTests {
    private var uninstallerTiles: some View {
        TileRow {
            StatTile(title: "Installed Apps", value: "142", caption: "Measuring… 12 of 142", symbol: "app.badge", tint: .blue, fillsHeight: true)
            StatTile(title: "Unused for 90 Days", value: "31", caption: "4.1 GB you might not need", symbol: "moon.zzz.fill", tint: .orange, fillsHeight: true)
            StatTile(title: "Leftovers of Removed Apps", value: "Not scanned", caption: "Files left by apps you removed", symbol: "shippingbox.fill", tint: .purple, fillsHeight: true)
        }
    }

    @Test func tileRowMeasuresItsCardsAtTheirMinimumWidth() {
        let minimum = LayoutProbe.minimumSize(uninstallerTiles)
        // One column of cards at their minimum width. Measured at the proposed zero width,
        // their text wrapped a character per line: 1,230 points tall.
        #expect(minimum.width == 180)
        #expect(minimum.height < 420, "minimum \(minimum)")
    }

    @Test func tileRowFillsTheWidthItIsGiven() {
        let size = LayoutProbe.size(uninstallerTiles, width: 780)
        #expect(size.width == 780)
        #expect(size.height < 120, "one row of cards, got \(size)")
    }

    @Test func uninstallerPageFitsTheSmallestWindow() throws {
        let services = try LayoutProbe.services()
        let model = UninstallerViewModel(services: services)
        let page = UninstallerView(model: model).environment(services.permissions)
        let minimum = LayoutProbe.minimumSize(page)
        #expect(minimum.width <= LayoutProbe.smallestPage.width, "minimum \(minimum)")
        let narrowest = LayoutProbe.size(page, width: LayoutProbe.smallestPage.width)
        #expect(narrowest.height <= LayoutProbe.smallestPage.height, "at the smallest width \(narrowest)")
    }

    @Test func updatesPageWithDetailsFitsTheSmallestWindow() throws {
        let model = try UpdatesTestRows.model(rows: [
            UpdatesTestRows.row("Writer", status: .updateAvailable, latest: "2.0"),
            UpdatesTestRows.row("Viewer", status: .upToDate),
        ])
        model.inspectedRowID = model.allRows.first?.id
        #expect(model.isInspectorPresented)
        let minimum = LayoutProbe.minimumSize(UpdatesView(model: model))
        #expect(minimum.width <= LayoutProbe.smallestPage.width, "minimum \(minimum)")
        let narrowest = LayoutProbe.size(UpdatesView(model: model), width: LayoutProbe.smallestPage.width)
        #expect(narrowest.height <= LayoutProbe.smallestPage.height, "at the smallest width \(narrowest)")
    }

    @Test func detailPanelAddsOnlyItsWidth() {
        let open = LayoutProbe.minimumSize(DetailPanelLayout(isPresented: true) {
            Color.clear.frame(minWidth: 200, minHeight: 100)
        } panel: {
            Color.clear
        })
        // The content, a divider and the panel; nothing else (an inspector column added the
        // sidebar's inset twice).
        #expect(abs(open.width - (200 + 1 + 330)) < 0.5, "minimum \(open)")
        #expect(open.height == 100)

        let closed = LayoutProbe.minimumSize(DetailPanelLayout(isPresented: false) {
            Color.clear.frame(minWidth: 200, minHeight: 100)
        } panel: {
            Color.clear
        })
        #expect(closed.width == 200, "minimum \(closed)")
    }

    /// `RootView` gives the detail column this frame, so no page decides its minimum height.
    @Test func columnFrameIgnoresThePagesMinimumHeight() {
        let tall = Color.clear.frame(minWidth: 300, minHeight: 2000)
        let minimum = LayoutProbe.minimumSize(tall.frame(minHeight: 0, maxHeight: .infinity))
        #expect(minimum.height == 0)
        #expect(minimum.width == 300)
    }
}
