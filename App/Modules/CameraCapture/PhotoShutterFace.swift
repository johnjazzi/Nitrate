import SwiftUI

/// Photo-mode shutter face: a light-grey donut with concave shading, sized to
/// sit inside the unchanged camera ring. The hole is transparent, so the live
/// preview shows through the middle.
///
/// Concavity is shading, not a painted gradient: the surface stays one light
/// grey tone, the near lip catches a rim highlight, and that lip casts a soft
/// shadow into the well below it — the depth cue that makes it read as dished
/// rather than domed. Everything is drawn as a blurred ring stroke so the
/// shading follows the wall and cannot fill the open hole.
struct PhotoShutterFace: View {
    var diameter: CGFloat = 68
    var thickness: CGFloat = 19

    private var band: some Shape { Circle().inset(by: thickness / 2) }

    var body: some View {
        ZStack {
            // One light grey surface, as specified.
            band.stroke(Color(white: 0.88), lineWidth: thickness)
            // Cast shadow: the near lip overhangs the well, so the wall just
            // inside it falls into shade.
            band.stroke(Color.black.opacity(0.26), lineWidth: thickness * 0.72)
                .blur(radius: thickness * 0.22)
                .offset(y: thickness * 0.22)
                .mask(LinearGradient(
                    stops: [.init(color: .white, location: 0),
                            .init(color: .white, location: 0.26),
                            .init(color: .clear, location: 0.52)],
                    startPoint: .top, endPoint: .bottom))
            // Rim highlight: the near lip itself catches the light.
            band.stroke(LinearGradient(
                stops: [.init(color: .white.opacity(0.55), location: 0),
                        .init(color: .clear, location: 0.42)],
                startPoint: .top, endPoint: .bottom), lineWidth: thickness * 0.5)
                .blur(radius: thickness * 0.14)
            // The far wall turns away from the light at the outer edge.
            band.stroke(LinearGradient(
                stops: [.init(color: .clear, location: 0.58),
                        .init(color: Color.black.opacity(0.12), location: 1)],
                startPoint: .top, endPoint: .bottom), lineWidth: thickness * 0.5)
                .blur(radius: thickness * 0.18)
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
    }
}

#if DEBUG
#Preview {
    ZStack {
        Color.black
        ZStack {
            PhotoShutterFace()
            Circle().stroke(.white.opacity(0.8), lineWidth: 2).frame(width: 78, height: 78)
        }
    }
}
#endif
