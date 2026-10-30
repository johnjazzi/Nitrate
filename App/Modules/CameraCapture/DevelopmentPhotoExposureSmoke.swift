#if DEBUG
import Foundation

/// Development-only sequential sensor check. All measured exposure values come
/// from the retained capture delegate's actual DNG metadata, never the request.
@MainActor
final class DevelopmentPhotoExposureSmoke {
    private let session: CameraSession
    private var latest: PhotoExposureSnapshot?
    private var shots: [[String: String]] = []

    init(session: CameraSession) { self.session = session }

    func run(completion: @escaping @MainActor @Sendable (Result<URL, Error>) -> Void) async {
        do {
            try await mode(true)
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PhotoExposureP0b", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let initial = try await ready { !$0.isoLocked && !$0.shutterLocked }
                let iso = min(max(Float(400), initial.isoRange.lowerBound), initial.isoRange.upperBound)
                let duration = min(max(1.0 / 60, initial.shutterRange.lowerBound), initial.shutterRange.upperBound)
                try await take("float-float", expectedISO: nil, expectedDuration: nil)

                session.setDevelopmentPhotoISO(iso)
                _ = try await ready { $0.isoLocked && !$0.shutterLocked }
                try await take("lock-float", expectedISO: iso, expectedDuration: nil)
                session.setDevelopmentPhotoEV(1)
                _ = try await ready { $0.isoLocked && !$0.shutterLocked && abs($0.ev - 1) < 0.001 }
                try await take("lock-float-ev", expectedISO: iso, expectedDuration: nil)
                session.setDevelopmentPhotoEV(0)
                _ = try await ready { $0.isoLocked && !$0.shutterLocked && abs($0.ev) < 0.001 }

                session.setDevelopmentPhotoDuration(duration)
                _ = try await ready { $0.isoLocked && $0.shutterLocked && abs($0.durationSeconds - duration) <= max(0.0000005, duration * 0.005) }
                session.setDevelopmentPhotoISOLocked(false)
                _ = try await ready { !$0.isoLocked && $0.shutterLocked }
                try await take("float-lock", expectedISO: nil, expectedDuration: duration)
                session.setDevelopmentPhotoEV(1)
                _ = try await ready { !$0.isoLocked && $0.shutterLocked && abs($0.ev - 1) < 0.001 }
                try await take("float-lock-ev", expectedISO: nil, expectedDuration: duration)
                session.setDevelopmentPhotoEV(0)
                _ = try await ready { !$0.isoLocked && $0.shutterLocked && abs($0.ev) < 0.001 }

                session.setDevelopmentPhotoISO(iso)
                _ = try await ready { $0.isoLocked && $0.shutterLocked }
                try await take("lock-lock", expectedISO: iso, expectedDuration: duration)
                session.setDevelopmentPhotoEV(1)
                _ = try await ready { $0.isoLocked && $0.shutterLocked && abs($0.ev - 1) < 0.001 }
                try await Task.sleep(for: .seconds(1))
                try await take("lock-lock-ev-meter-only", expectedISO: iso, expectedDuration: duration)

                if CommandLine.arguments.contains("--photo-controls-core-only") {
                    try await mode(false)
                    let report: [String: Any] = ["status": "coreControlsPassed", "shots": shots,
                        "videoConfigurationRestored": true, "rangeEndpointsVerified": false,
                        "colorCalibrationVerified": false]
                    try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                        .write(to: directory.appendingPathComponent("exposure.json"), options: .atomic)
                    print("Photo exposure core controls passed: seven validated RAW captures")
                    completion(.success(directory))
                    return
                }
                session.setDevelopmentPhotoDuration(initial.shutterRange.lowerBound)
                // The sensor quantizes the advertised 14 µs endpoint to 18 µs
                // on this device. Record both values and bound that measured
                // quantization; do not wait for an unrepresentable exact value.
                let minimumTolerance = max(0.000005, initial.shutterRange.lowerBound * 0.005)
                _ = try await ready { $0.isoLocked && $0.shutterLocked && abs($0.durationSeconds - initial.shutterRange.lowerBound) <= minimumTolerance }
                try await take("supported-minimum-quantized", expectedISO: iso,
                    expectedDuration: initial.shutterRange.lowerBound, durationTolerance: minimumTolerance)
                session.setDevelopmentPhotoDuration(initial.shutterRange.upperBound)
                _ = try await ready { $0.isoLocked && $0.shutterLocked && abs($0.durationSeconds - initial.shutterRange.upperBound) <= max(0.0000005, initial.shutterRange.upperBound * 0.005) }
                try await take("supported-maximum", expectedISO: iso, expectedDuration: initial.shutterRange.upperBound)
                try await mode(false)
                let report: [String: Any] = ["status": "passed", "shots": shots,
                    "videoConfigurationRestored": true, "videoAudioProof": "notRun",
                    "colorCalibrationVerified": false,
                    "minimumDuration": initial.shutterRange.lowerBound,
                    "maximumDuration": initial.shutterRange.upperBound]
                try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                    .write(to: directory.appendingPathComponent("exposure.json"), options: .atomic)
                completion(.success(directory))
            } catch {
                try? await mode(false)
                let report: [String: Any] = ["status": "failed", "failure": String(describing: error),
                                             "shots": shots, "colorCalibrationVerified": false]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) {
                    try? data.write(to: directory.appendingPathComponent("exposure.json"), options: .atomic)
                }
                throw error
            }
        } catch { completion(.failure(error)) }
    }

    private func mode(_ enabled: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.setDevelopmentPhotoMode(enabled, onUpdate: { [weak self] snapshot in
                self?.latest = snapshot
            }, completion: { result in continuation.resume(with: result) })
        }
    }

    private func ready(_ predicate: (PhotoExposureSnapshot) -> Bool) async throws -> PhotoExposureSnapshot {
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            try Task.checkCancellation()
            // Capture readiness is independent of scene-meter convergence.
            // A moving scene may never converge; verify the captured pins instead.
            if let snapshot = latest, snapshot.canCapture, predicate(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw SmokeError.notReady(String(describing: latest))
    }

    private func take(_ name: String, expectedISO: Float?, expectedDuration: Double?, durationTolerance: Double = 0.0000005) async throws {
        let before = try await ready { _ in true }
        let url: URL = try await withCheckedThrowingContinuation { continuation in
            session.captureDevelopmentPhoto { result in continuation.resume(with: result) }
        }
        let data = try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("capture.json"))
        guard let metadata = try JSONSerialization.jsonObject(with: data) as? [String: String],
              metadata["status"] == "complete", metadata["dngReadable"] == "true",
              let actualISO = metadata["iso"].flatMap(Double.init), actualISO.isFinite, actualISO > 0,
              let actualDuration = metadata["exposure"].flatMap(Double.init), actualDuration.isFinite, actualDuration > 0 else {
            throw SmokeError.missingMeasuredExposure(name)
        }
        var record = ["case": name, "dng": url.path, "measuredISO": String(actualISO),
                      "measuredDuration": String(actualDuration), "isoLocked": String(before.isoLocked),
                      "shutterLocked": String(before.shutterLocked), "ev": String(before.ev),
                      "targetLimited": String(before.targetLimited)]
        if let expectedISO {
            record["requestedISO"] = String(expectedISO)
            guard abs(actualISO - Double(expectedISO)) <= max(1, Double(expectedISO) * 0.01) else {
                shots.append(record)
                throw SmokeError.pinMismatch(name, "ISO", Double(expectedISO), actualISO)
            }
        }
        if let expectedDuration {
            record["requestedDuration"] = String(expectedDuration)
            guard abs(actualDuration - expectedDuration) <= max(durationTolerance, expectedDuration * 0.005) else {
                shots.append(record)
                throw SmokeError.pinMismatch(name, "duration", expectedDuration, actualDuration)
            }
        }
        shots.append(record)
        print("Photo exposure P0b shot: \(name); ISO=\(actualISO); duration=\(actualDuration)")
    }

    private enum SmokeError: Error {
        case notReady(String)
        case missingMeasuredExposure(String)
        case pinMismatch(String, String, Double, Double)
    }
}
#endif
