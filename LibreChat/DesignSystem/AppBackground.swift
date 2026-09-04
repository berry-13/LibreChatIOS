import SwiftUI

struct AppBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // LibreChat's flat canvas: pure white in light mode, pure black in
        // dark mode, with no gradient washes behind any screen.
        Color(uiColor: .systemBackground)
            .ignoresSafeArea()
    }
}
