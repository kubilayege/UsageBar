import SwiftUI

struct MenuBarLabelView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        let segments = store.menuBarSegments
        HStack(spacing: 6) {
            if segments.isEmpty {
                Image(nsImage: MenuBarIcon.whiteLogo())
            } else {
                ForEach(segments) { seg in
                    HStack(spacing: 3) {
                        Circle().fill(seg.dot).frame(width: 6, height: 6)
                        Text(seg.text).foregroundStyle(seg.color)
                    }
                }
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
    }
}
