import SwiftUI

/// Shared border tokens for the camera controls that draw a rim or a hairline.
/// Both surface styles consume the same geometry, so changing style can never
/// move or resize a control; only the drawing differs. The numbers stay the
/// minimal pass's values, so callers and the border contract tests that pin them
/// are unaffected by the style switch.
enum CameraControlBorder {
    static let lineWidth: CGFloat = 1
    static let cornerRadius: CGFloat = 12
}

/// Fixed 44pt toolbar keys use an actual circle, including the hit region.
///
/// The style itself stays stateless: the circular face is drawn by
/// `CameraRoundSurface`, a view modifier, so the environment read happens in the
/// view graph rather than inside `makeBody`.
struct CameraRoundButtonStyle: ButtonStyle {
    var faceColor: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(CameraRoundSurface(faceColor: faceColor, isPressed: configuration.isPressed))
    }
}

/// The circular key face.
///
/// `.minimal` (the default) keeps one dark neutral fill with a restrained accent
/// cast. `.classic` restores the translucent material key with a rim gradient and
/// a cast shadow. Both keep the caller's `faceColor` as a tint in the face, so a
/// stock-aware accent survives either style.
struct CameraRoundSurface: ViewModifier {
    var faceColor: Color?
    var isPressed = false

    @Environment(\.cameraUIStyle) private var uiStyle

    func body(content: Content) -> some View {
        if uiStyle == .classic {
            content
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay {
                            Circle().fill((faceColor ?? .black).opacity(isPressed ? 0.7 : 0.45))
                        }
                }
                .overlay {
                    Circle().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.38), .black.opacity(0.5)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.35), radius: isPressed ? 1 : 3, y: 2)
                .contentShape(Circle())
        } else {
            content
                .background {
                    Circle()
                        .fill(.black.opacity(isPressed ? 0.66 : 0.5))
                        .overlay {
                            Circle().fill((faceColor ?? .clear).opacity(isPressed ? 0.42 : 0.28))
                        }
                }
                .contentShape(Circle())
        }
    }
}

/// Shared face for rectangular camera controls.
///
/// `.minimal` (the default) is one dark fill and a restrained pressed opacity. `.classic`
/// restores the machined translucent plate: material body, bright-over-dark bevel
/// and a cast shadow that collapses on press. A caller can tint a control by
/// supplying `faceColor` in either style; the tint is the caller's accent, kept
/// independent of the surface style.
///
/// Everything that draws a plate goes through here — the toolbar keys, the lens
/// selector and the manual controls — so the manual faces follow the screen's
/// style without carrying a style of their own.
struct CameraRaisedButtonStyle: ButtonStyle {
    /// Tint of the face. Nil keeps it neutral.
    var faceColor: Color?
    var cornerRadius: CGFloat = CameraControlBorder.cornerRadius

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(CameraRaisedSurface(faceColor: faceColor, cornerRadius: cornerRadius,
                                          isPressed: configuration.isPressed))
    }
}

/// The rectangular face itself.
struct CameraRaisedSurface: ViewModifier {
    var faceColor: Color?
    var cornerRadius: CGFloat = CameraControlBorder.cornerRadius
    var isPressed = false

    @Environment(\.cameraUIStyle) private var uiStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if uiStyle == .classic {
            content
                .background {
                    shape.fill(.ultraThinMaterial)
                        .overlay { shape.fill(classicFill) }
                }
                .overlay {
                    shape.strokeBorder(classicBevel, lineWidth: CameraControlBorder.lineWidth)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(isPressed ? 0.16 : 0.38),
                        radius: isPressed ? 1 : 4,
                        x: 0,
                        y: isPressed ? 1 : 2)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isPressed)
                .contentShape(shape)
        } else {
            content
                .background {
                    shape.fill(minimalBase)
                        .overlay { shape.fill(minimalTint) }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isPressed)
                .contentShape(shape)
        }
    }

    /// Classic: barely tinted, because the material supplies the body and the
    /// preview still reads past the control.
    private var classicFill: Color {
        guard let faceColor else { return .black.opacity(isPressed ? 0.34 : 0.18) }
        return faceColor.opacity(isPressed ? 0.78 : 0.62)
    }

    /// Classic: bright along the top edge, dark underneath.
    private var classicBevel: LinearGradient {
        LinearGradient(
            colors: [.white.opacity(isPressed ? 0.16 : 0.42),
                     .white.opacity(0.05),
                     .black.opacity(isPressed ? 0.50 : 0.42)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Minimal: one dark neutral fill. Pressing deepens it slightly instead of
    /// moving a bevel, and keeps the caller's glyph readable on any accent.
    private var minimalBase: Color {
        .black.opacity(isPressed ? 0.66 : 0.5)
    }

    /// Minimal: the accent cast for a selected/tinted control, kept restrained so
    /// it reads as a matching dark fill rather than an accent-coloured plate.
    private var minimalTint: Color {
        (faceColor ?? .clear).opacity(isPressed ? 0.42 : 0.28)
    }
}

/// Recessed face for readouts. Layout padding stays with the caller.
///
/// `.minimal` (the default) is one flat black fill. `.classic` restores the
/// material recess with a dark top rim and a light bottom rim.
struct CameraInsetSurface: ViewModifier {
    @Environment(\.cameraUIStyle) private var uiStyle

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CameraControlBorder.cornerRadius, style: .continuous)
        if uiStyle == .classic {
            content
                .background {
                    shape.fill(.ultraThinMaterial)
                        .overlay { shape.fill(Color.black.opacity(0.18)) }
                }
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(colors: [.black.opacity(0.76), .black.opacity(0.20), .white.opacity(0.68)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: CameraControlBorder.lineWidth)
                        .allowsHitTesting(false)
                }
                .contentShape(shape)
        } else {
            content
                .background { shape.fill(Color.black.opacity(0.5)) }
                .contentShape(shape)
        }
    }
}

/// The plate a well paints. One definition, shared by the padded control well
/// and by the borderless backing the Minimal clusters sit in.
///
/// `.minimal` (the default) is one flat neutral fill with no rim, material or
/// shadow. `.classic` restores the translucent raised plate with its inset
/// dark-over-light rim.
struct CameraWellFace: View {
    var cornerRadius: CGFloat = CameraControlBorder.cornerRadius

    @Environment(\.cameraUIStyle) private var uiStyle

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if uiStyle == .classic {
            shape.fill(.ultraThinMaterial)
                .overlay { shape.fill(Color.black.opacity(0.18)) }
                .overlay {
                    // The outer rim is inset: dark above, light below. The keys
                    // inside retain their raised bevels.
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.black.opacity(0.76), .black.opacity(0.20),
                                     .white.opacity(0.68)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: CameraControlBorder.lineWidth
                    )
                    .allowsHitTesting(false)
                }
        } else {
            // Charcoal, not black: a black fill disappears over dark footage.
            // Kept translucent so the plate stays a hint over the image rather
            // than a panel, and it still reads on a bright scene.
            shape.fill(Color(white: 0.11).opacity(0.62))
        }
    }
}

/// A plate that groups related controls. It keeps the existing padding and hit
/// region in both styles; only the simulated hardware differs.
struct CameraControlWell: ViewModifier {
    var cornerRadius: CGFloat = CameraControlBorder.cornerRadius
    var horizontalPadding: CGFloat = 6

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 5)
            .background { CameraWellFace(cornerRadius: cornerRadius) }
            .contentShape(shape)
    }
}

/// Minimal's borderless well behind a face that already fills its slot.
///
/// The stock entry, the status LCD, the exposure column and the mode row are
/// placed by the shooting bar and the mode strip, so their footprints are
/// fixed. This only paints the shared fill behind them: no padding, no size
/// change and no hit region, so the plate hugs whatever ink it is given and the
/// caller can put its flexible frame outside it. Both styles share this exact
/// footprint: Classic adds the recessed bevel, Minimal keeps a borderless fill.
struct CameraWellBacking: ViewModifier {
    var cornerRadius: CGFloat = CameraControlBorder.cornerRadius
    /// Pulls the fill in from the face's edges without moving the face, so a
    /// plate around a 28pt disc need not be the height of the 44pt touch row.
    var verticalInset: CGFloat = 0

    @Environment(\.cameraUIStyle) private var uiStyle

    func body(content: Content) -> some View {
        content.background {
            CameraWellFace(cornerRadius: cornerRadius)
                .padding(.vertical, verticalInset)
                .allowsHitTesting(false)
        }
    }
}

extension View {
    /// Wrap a cluster of controls in the control plate.
    func cameraControlWell(cornerRadius: CGFloat = CameraControlBorder.cornerRadius, horizontalPadding: CGFloat = 6) -> some View {
        modifier(CameraControlWell(cornerRadius: cornerRadius, horizontalPadding: horizontalPadding))
    }

    /// Seat a face that already fills its slot in the shared Minimal well.
    func cameraWellBacking(cornerRadius: CGFloat = CameraControlBorder.cornerRadius,
                           verticalInset: CGFloat = 0) -> some View {
        modifier(CameraWellBacking(cornerRadius: cornerRadius, verticalInset: verticalInset))
    }
}
