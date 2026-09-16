import AppKit
import SwiftUI

enum AppBranding {
    static let logo: NSImage = {
        // The app bundle carries the artwork directly; SwiftPM supplies it for `swift run`.
        var url = Bundle.main.url(forResource: "AppLogo", withExtension: "png")
        #if SWIFT_PACKAGE
        if url == nil { url = Bundle.module.url(forResource: "AppLogo", withExtension: "png") }
        #endif
        let image = url.flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "UsageBar")!
        image.accessibilityDescription = "UsageBar"
        return image
    }()
}

struct AppLogoView: View {
    var size: CGFloat

    var body: some View {
        Image(nsImage: AppBranding.logo)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
