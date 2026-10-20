import CoreGraphics
import RelayCore
import Testing
@testable import RelayUI

private func close(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < 0.001 && abs(a.minY - b.minY) < 0.001 && abs(a.width - b.width) < 0.001 && abs(a.height - b.height) < 0.001
}

@Suite @MainActor struct BadgeGeometryTests {
    private let bounds = CGRect(x: 0, y: 0, width: 24, height: 22)
    private let image = CGRect(x: 4, y: 3, width: 16, height: 16)

    @Test func sizes() {
        #expect(BadgeGeometry.size(for: .number(3)) == CGSize(width: 13, height: 13))
        #expect(BadgeGeometry.size(for: .dot) == CGSize(width: 7, height: 7))
        #expect(BadgeGeometry.size(for: .none) == .zero)
    }

    @Test func digitOverTheTopRightCornerClampedInside() {
        #expect(close(BadgeGeometry.frame(for: .number(3), in: bounds, imageRect: image, flipped: false),
                      CGRect(x: 11, y: 9, width: 13, height: 13)))
        #expect(close(BadgeGeometry.frame(for: .number(3), in: bounds, imageRect: image, flipped: true),
                      CGRect(x: 11, y: 0, width: 13, height: 13)))
    }

    @Test func dotPlacement() {
        #expect(close(BadgeGeometry.frame(for: .dot, in: bounds, imageRect: image, flipped: false),
                      CGRect(x: 15.8, y: 14.45, width: 7, height: 7)))
    }

    @Test func noneHasNoFrameAndTheShortFormUsesTheBounds() {
        #expect(BadgeGeometry.frame(for: .none, in: bounds) == .zero)
        #expect(close(BadgeGeometry.frame(for: .dot, in: bounds), BadgeGeometry.frame(for: .dot, in: bounds, imageRect: bounds, flipped: false)))
    }

    @Test func viewState() {
        let view = BadgeView(frame: .zero)
        #expect(view.isHidden)
        view.badge = .number(2)
        #expect(!view.isHidden)
        view.dimmed = true
        #expect(view.alphaValue == 0.5)
        view.dimmed = false
        #expect(view.alphaValue == 1)
        #expect(view.hitTest(.zero) == nil)
    }
}
