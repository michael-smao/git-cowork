import CoreGraphics
import Testing
@testable import GitCoworkCore

@Suite struct BadgeRowFitTests {
    @Test func oneBadgeThatFitsHidesNothing() {
        let fit = BadgeRowFit.fit(count: 1, nameWidth: 50, available: 80)
        #expect(fit == BadgeRowFit(textWidth: 50, counter: nil, hidesSomething: false))
    }

    @Test func cutNameHidesSomething() {
        let fit = BadgeRowFit.fit(count: 1, nameWidth: 120, available: 60)
        #expect(fit.textWidth == 60)
        #expect(fit.counter == nil)
        #expect(fit.hidesSomething)
    }

    @Test func moreBadgesGetACounter() {
        let fit = BadgeRowFit.fit(count: 3, nameWidth: 40, available: 80)
        #expect(fit.textWidth == 40)
        #expect(fit.counter == 2)
        #expect(fit.hidesSomething)
    }

    @Test func tooNarrowFoldsEverythingIntoTheCounter() {
        let fit = BadgeRowFit.fit(count: 2, nameWidth: 120, available: 12)
        #expect(!fit.showsFirst)
        #expect(fit.counter == 2)
        #expect(fit.hidesSomething)
        #expect(BadgeRowFit.fit(count: 1, nameWidth: 120, available: -5).counter == 1)
    }

    @Test func shortNameFitsBelowTheMinimum() {
        // "v1" is narrower than minTextWidth but needs no cutting.
        let fit = BadgeRowFit.fit(count: 1, nameWidth: 12, available: 15)
        #expect(fit == BadgeRowFit(textWidth: 12, counter: nil, hidesSomething: false))
    }

    @Test func noBadges() {
        let fit = BadgeRowFit.fit(count: 0, nameWidth: 0, available: 100)
        #expect(!fit.showsFirst && fit.counter == nil && !fit.hidesSomething)
    }
}

@Suite struct BadgeListLayoutTests {
    private let container = CGRect(x: 0, y: 100, width: 300, height: 400)   // visible rows 100...500

    private func make(_ widths: [CGFloat], at anchor: CGPoint) -> BadgeListLayout {
        BadgeListLayout.make(widths: widths, badgeHeight: 20, spacing: 4, padding: 4, anchor: anchor, container: container)
    }

    @Test func dropsDownFromTheRow() {
        let l = make([80, 150, 60], at: CGPoint(x: 12, y: 200))
        #expect(l.frame == CGRect(x: 8, y: 196, width: 158, height: 76))
        #expect(l.tops == [4, 28, 52])
        #expect(l.widths == [80, 150, 60])
        // The first badge sits where the row's own badge is.
        #expect(l.frame.minY + l.tops[0] == 200)
    }

    @Test func growsUpwardWithoutRoomBelow() {
        let l = make([80, 80, 80], at: CGPoint(x: 12, y: 470))
        #expect(l.frame.maxY <= container.maxY)
        // The last badge ends on the row.
        #expect(l.frame.minY + l.tops[2] == 470)
    }

    @Test func staysInsideOnTheRight() {
        let l = make([200], at: CGPoint(x: 250, y: 200))
        #expect(l.frame.maxX == container.maxX)
        #expect(l.frame.width == 208)
    }

    @Test func cutsBadgesWiderThanTheContainer() {
        let l = make([500, 40], at: CGPoint(x: 12, y: 200))
        #expect(l.frame.minX == 0)
        #expect(l.frame.width == 300)
        #expect(l.widths == [292, 40])
    }

    @Test func tallerThanTheContainerStartsAtItsTop() {
        let l = make(Array(repeating: 50, count: 30), at: CGPoint(x: 12, y: 300))
        #expect(l.frame.minY == container.minY)
    }

    @Test func empty() {
        #expect(make([], at: .zero).frame == .zero)
    }
}
