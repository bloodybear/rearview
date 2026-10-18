#if !LST_EXCLUDE_DEBUG_FEATURES
import CoreGraphics

/// One-off development launch override used to start a capture session without
/// a system-global hotkey or a simulated drag. Coordinates use a top-left
/// normalized origin so they can be copied from screen captures.
struct DebugSelectionRegion: Equatable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    init?(argumentValue: String) {
        let components = argumentValue.split(separator: ",", omittingEmptySubsequences: false)
        guard components.count == 4 else { return nil }
        let values = components.compactMap { Double($0) }
        guard values.count == 4, values.allSatisfy(\.isFinite) else { return nil }

        let x = CGFloat(values[0])
        let y = CGFloat(values[1])
        let width = CGFloat(values[2])
        let height = CGFloat(values[3])
        guard x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1, y + height <= 1 else { return nil }

        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    func rect(in screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.minX + x * screenFrame.width,
            y: screenFrame.minY + (1 - y - height) * screenFrame.height,
            width: width * screenFrame.width,
            height: height * screenFrame.height
        )
    }
}
#endif
