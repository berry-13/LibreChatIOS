import SwiftUI

private struct AdaptiveGlassModifier<SurfaceShape: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: SurfaceShape

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(.background, in: shape)
                .overlay { shape.stroke(.primary.opacity(0.18), lineWidth: 1) }
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay { shape.stroke(.white.opacity(0.16), lineWidth: 0.5) }
        }
    }
}

private struct AdaptiveSurfaceModifier<SurfaceShape: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: SurfaceShape

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(.background, in: shape)
                .overlay { shape.stroke(.primary.opacity(0.18), lineWidth: 1) }
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

private struct AdaptiveProminentButtonModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.buttonStyle(.borderedProminent)
        } else if #available(iOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

private struct AdaptiveGlassButtonModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.buttonStyle(.bordered)
        } else if #available(iOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// iOS 26 `.clear` Liquid Glass — more transparent than `.regular`, for
/// surfaces whose content should show through vividly (icon-bearing
/// dropdowns). Falls back identically to the regular helper.
@available(iOS 26.0, *)
private struct AdaptiveClearInteractiveGlassModifier<SurfaceShape: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: SurfaceShape
    var interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(.background, in: shape)
                .overlay { shape.stroke(.primary.opacity(0.18), lineWidth: 1) }
        } else {
            let glass: Glass = interactive ? Glass.clear.interactive() : .clear
            content.glassEffect(glass, in: shape)
        }
    }
}

extension View {
    func adaptiveGlass<S: Shape>(in shape: S) -> some View {
        modifier(AdaptiveGlassModifier(shape: shape))
    }

    @ViewBuilder
    func adaptiveClearGlass<S: Shape>(in shape: S, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            modifier(AdaptiveClearInteractiveGlassModifier(shape: shape, interactive: interactive))
        } else {
            modifier(AdaptiveGlassModifier(shape: shape))
        }
    }

    /// `.regular` Liquid Glass tinted with the theme's primary color — the
    /// white/black inversion in a true glass material (translucent, with the
    /// specular lensing and press response of iOS 26 glass).
    @ViewBuilder
    func adaptiveThemeTintedGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            let glass = Glass.regular.tint(Color.primary).interactive()
            self.glassEffect(glass, in: shape)
        } else {
            self.background(Color.primary, in: shape)
        }
    }

    /// `.regular` Liquid Glass whose specular highlight reacts to touches.
    @ViewBuilder
    func adaptiveInteractiveGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            let glass = Glass.regular.interactive()
            self.glassEffect(glass, in: shape)
        } else {
            modifier(AdaptiveGlassModifier(shape: shape))
        }
    }

    func adaptiveSurface<S: Shape>(in shape: S) -> some View {
        modifier(AdaptiveSurfaceModifier(shape: shape))
    }

    func adaptiveProminentButtonStyle() -> some View {
        modifier(AdaptiveProminentButtonModifier())
    }

    func adaptiveGlassButtonStyle() -> some View {
        modifier(AdaptiveGlassButtonModifier())
    }
}
