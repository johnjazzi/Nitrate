/// Ephemeral, in-memory progress for an active render-queue job.
///
/// It exists only for the lifetime of the work so the inline Develop preview
/// overlay can show genuine progress. It is deliberately not persisted: a
/// relaunch has no in-flight render to recover and must never present a stored
/// percentage, or a save that has not been confirmed by Photos, as if it were
/// current.
struct RenderJobProgress: Sendable, Equatable {
    enum Phase: Sendable {
        /// The renderer is producing the movie file.
        case rendering
        /// The movie is rendered; it is being delivered to Photos, including a
        /// retry of an already-rendered, retained output.
        case saving
    }

    let phase: Phase
    /// `0...1` while `.rendering` tracks real work, or `nil` when the render
    /// cannot report a meaningful fraction (for example an injected render
    /// operation that does not drive the frame loop).
    let fractionComplete: Double?
}
