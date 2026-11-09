import SwiftUI

// Liquid Glass (iOS 26+). Con un SDK più vecchio, o su iOS precedenti, si usano i materiali sfocati.
// `#if compiler(>=6.2)` = Xcode 26 o successivo, l'unico che conosce le API del vetro.

extension View {
    /// Vetro a forma di capsula (chip, etichette, piccoli pulsanti).
    @ViewBuilder
    func glassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            glassEffect(Self.glass(tint: tint, interactive: interactive), in: Capsule())
        } else {
            background(tint.map { AnyShapeStyle($0.opacity(0.85)) } ?? AnyShapeStyle(.ultraThinMaterial), in: Capsule())
        }
        #else
        background(tint.map { AnyShapeStyle($0.opacity(0.85)) } ?? AnyShapeStyle(.ultraThinMaterial), in: Capsule())
        #endif
    }

    /// Vetro con angoli arrotondati (riquadri, mini player).
    @ViewBuilder
    func glassRect(_ radius: CGFloat, tint: Color? = nil, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            glassEffect(Self.glass(tint: tint, interactive: interactive), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
        #else
        background(.ultraThinMaterial, in: shape)
        #endif
    }

    /// Vetro circolare (pulsanti del player).
    @ViewBuilder
    func glassCircle(tint: Color? = nil, interactive: Bool = true) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            glassEffect(Self.glass(tint: tint, interactive: interactive), in: Circle())
        } else {
            background(.ultraThinMaterial, in: Circle())
        }
        #else
        background(.ultraThinMaterial, in: Circle())
        #endif
    }

    /// Pulsanti grandi (Riproduci, Casuale, Segui): vetro su iOS 26, stile "bordered" prima.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
        #else
        if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26, *)
    fileprivate static func glass(tint: Color?, interactive: Bool) -> Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
    #endif

    /// Barra dei tab che si riduce scorrendo verso il basso (iOS 26).
    @ViewBuilder
    func minimizingTabBar() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// true se l'app è compilata con l'SDK nuovo e gira su iOS 26+: il mini player va nella barra dei tab.
var usesTabAccessory: Bool {
    #if compiler(>=6.2)
    if #available(iOS 26, *) { return true }
    #endif
    return false
}
