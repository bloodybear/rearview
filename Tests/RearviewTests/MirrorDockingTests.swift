import Foundation
import Testing
@testable import Rearview

@Suite
struct MirrorDockingTests {
    @Test func movePreviewKeepsGhostWhenPlacementMatches() {
        #expect(mirrorDockPreviewPresentation(
            for: .move
        ) == .seamAndGhost)
        #expect(mirrorDockPreviewPresentation(
            for: .resize(placementMatchesCurrentFrame: true)
        ) == .seamOnly)
        #expect(mirrorDockPreviewPresentation(
            for: .resize(placementMatchesCurrentFrame: false)
        ) == .seamAndGhost)
    }

    @Test func dockedFrameUsesGapAlignmentAndVisibleFrameBounds() {
        let selection = CGRect(x: 400, y: 300, width: 200, height: 100)
        let visible = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let placement = mirrorDockedFrame(
            selection: selection,
            windowSize: CGSize(width: 300, height: 200),
            state: .right,
            visibleFrames: [visible],
            chromeHeight: 40,
            borderOutset: 2,
            alignment: .center
        )
        guard let placement else {
            Issue.record("expected a visible right docking placement")
            return
        }
        #expect(placement.scale == 1)
        #expect(placement.frame.minX == selection.maxX + 2 + MirrorDockingState.dockedGap)
        #expect(placement.frame.height == 200)
        #expect(placement.frame.maxY <= visible.maxY)
        #expect(placement.frame.minY >= visible.minY)
        #expect(mirrorDockedFrame(
            selection: selection,
            windowSize: CGSize(width: 300, height: 200),
            state: .undocked,
            visibleFrames: [visible], chromeHeight: 40, borderOutset: 2, alignment: .center
        ) == nil)
        #expect(mirrorDockedFrame(
            selection: selection,
            windowSize: CGSize(width: 300, height: 200),
            state: .right,
            visibleFrames: [], chromeHeight: 40, borderOutset: 2, alignment: .center
        ) == nil)
    }

    @Test func dockingScalesToFitOrRejectsWhenMinimumScaleCannotFit() {
        let selection = CGRect(x: 500, y: 100, width: 100, height: 100)
        let visibleFrames = [
            CGRect(x: 0, y: 0, width: 600, height: 400),
            CGRect(x: 600, y: 0, width: 600, height: 400)
        ]
        let placement = mirrorDockedFrame(
            selection: selection,
            windowSize: CGSize(width: 300, height: 100),
            state: .right,
            visibleFrames: visibleFrames,
            chromeHeight: OverlayControlBarMetrics.height,
            borderOutset: 0,
            alignment: .start
        )
        #expect(placement != nil)
        #expect(placement!.scale >= MirrorDockingState.minimumScale)
        #expect(placement!.scale <= 1)
        #expect(mirrorDockedFrame(
            selection: CGRect(x: 0, y: 0, width: 100, height: 100),
            windowSize: CGSize(width: 1000, height: 1000),
            state: .right,
            visibleFrames: [CGRect(x: 0, y: 0, width: 100, height: 100)],
            chromeHeight: 40, borderOutset: 0, alignment: .center
        ) == nil)
    }

    @Test func freeDockCandidateRequiresEdgeProximityAndFullShortEdgeCoverage() {
        let selection = CGRect(x: 100, y: 100, width: 200, height: 100)
        let rightFrame = CGRect(x: 305, y: 100, width: 100, height: 100)
        #expect(mirrorFreeDockCandidate(
            windowFrame: rightFrame, selection: selection
        ) == .right)
        #expect(mirrorDockingCandidateMatches(
            windowFrame: rightFrame, selection: selection, state: .right
        ))
        #expect(!mirrorDockingCandidateMatches(
            windowFrame: rightFrame, selection: selection, state: .left
        ))
        #expect(mirrorFreeDockCandidate(
            windowFrame: CGRect(x: 305, y: 250, width: 100, height: 40),
            selection: selection, tangentialTolerance: 0
        ) == nil)
        #expect(!mirrorDockingCandidateMatches(
            windowFrame: CGRect(x: 305, y: 250, width: 100, height: 40),
            selection: selection, state: .right, tangentialTolerance: 0
        ))
        #expect(!mirrorDockingCandidateMatches(
            windowFrame: rightFrame, selection: selection, state: .undocked
        ))
    }

    @Test func dockedResizeChecksRawFrameBeforePlacementCorrection() {
        let selection = CGRect(x: 100, y: 100, width: 200, height: 100)
        let chromeHeight: CGFloat = 40
        let rightFrame = CGRect(x: 305, y: 100, width: 100, height: 100)

        // Moving the short docking edge beyond the tangential tolerance must
        // be rejected before a final placement can clamp it back into range.
        let tangentiallyInvalid = CGRect(
            x: rightFrame.minX,
            y: selection.maxY + 1,
            width: rightFrame.width,
            height: rightFrame.height
        )
        #expect(!mirrorDockingCandidateMatches(
            windowFrame: tangentiallyInvalid,
            selection: selection,
            state: .right,
            snapDistance: 16,
            tangentialTolerance: 0,
            chromeHeight: chromeHeight
        ))

        // Moving the docking edge away from the selection beyond the normal
        // snap distance must be rejected for the same reason.
        let normallyInvalid = CGRect(
            x: selection.maxX + 17,
            y: rightFrame.minY,
            width: rightFrame.width,
            height: rightFrame.height
        )
        #expect(!mirrorDockingCandidateMatches(
            windowFrame: normallyInvalid,
            selection: selection,
            state: .right,
            snapDistance: 16,
            tangentialTolerance: 0,
            chromeHeight: chromeHeight
        ))

        // The corrected placement itself is valid, which is exactly why the
        // raw-frame check must happen before placement correction.
        let corrected = mirrorDockedFrame(
            selection: selection,
            windowSize: tangentiallyInvalid.size,
            state: .right,
            visibleFrames: [CGRect(x: 0, y: 0, width: 1200, height: 900)],
            chromeHeight: chromeHeight,
            borderOutset: 0,
            alignment: .center
        )
        #expect(corrected != nil)
        #expect(mirrorDockingCandidateMatches(
            windowFrame: corrected!.frame,
            selection: selection,
            state: .right,
            snapDistance: 16,
            tangentialTolerance: 0,
            chromeHeight: chromeHeight
        ))
    }

    @Test func dockingAnchorAndSeamFollowSelectionGeometry() {
        let selection = CGRect(x: 100, y: 100, width: 200, height: 100)
        let frame = CGRect(x: 305, y: 100, width: 100, height: 100)
        let anchor = mirrorDockingAnchor(
            frame: frame, selection: selection, state: .right, chromeHeight: 40
        )
        if case .relative(let ratio) = anchor {
            #expect(expectApproximatelyEqual(ratio, 0.6))
        } else {
            Issue.record("free docking should produce a relative anchor")
        }
        let edge = mirrorDockingMirrorEdgeRect(
            frame: frame, state: .right, chromeHeight: 40
        )
        #expect(edge.height == 60)
        #expect(mirrorDockingAlongEdgeIsCovered(
            selection: selection, frame: frame, state: .right, chromeHeight: 40
        ))
        let seam = mirrorDockingSeamRect(
            placement: frame, state: .right, selection: selection,
            borderOutset: 2, borderShadowReach: 3, chromeHeight: 40
        )
        #expect(seam != nil)
        #expect(seam!.width == MirrorDockingState.seamThickness)
        #expect(seam!.height > 0)
        #expect(mirrorDockingSeamRect(
            placement: frame, state: .undocked, selection: selection,
            borderOutset: 2, borderShadowReach: 3
        ) == nil)
    }

    @Test func undockedFrameIsClampedToNearestVisibleFrame() {
        let visible = CGRect(x: 0, y: 0, width: 1200, height: 900)
        #expect(mirrorUndockedFrame(
            savedFrame: nil,
            defaultFrame: CGRect(x: 300, y: 200, width: 400, height: 300),
            visibleFrames: [visible]
        ) == CGRect(x: 300, y: 200, width: 400, height: 300))
        #expect(mirrorUndockedFrame(
            savedFrame: nil,
            defaultFrame: CGRect(x: 1900, y: 500, width: 400, height: 300),
            visibleFrames: [visible]
        ) == CGRect(x: 800, y: 500, width: 400, height: 300))
        #expect(mirrorUndockedFrame(
            savedFrame: nil,
            defaultFrame: CGRect(x: -100, y: -100, width: 2000, height: 1500),
            visibleFrames: [visible]
        ) == visible)
    }
}
