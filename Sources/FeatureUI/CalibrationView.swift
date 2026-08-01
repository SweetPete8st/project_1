#if os(iOS) && canImport(SwiftUI)
import CaptureKit
import ShredCore
import SwiftUI

/// Pocket-calibration flow, FR-20/21 + 06 §3: confirm pocket → 5 s still baseline
/// (variance-gated, max 3 attempts) → pocket it and push off.
public struct CalibrationView: View {
    @Environment(AppModel.self) private var model

    private enum Step {
        case confirmPocket
        case capturing(attempt: Int, progress: Double)
        case pocketIt
        case degraded
    }

    @State private var step: Step = .confirmPocket
    @State private var result: CalibrationRecord?
    @State private var captureTask: Task<Void, Never>?

    public init() {}

    public var body: some View {
        VStack(spacing: 28) {
            Spacer()
            switch step {
            case .confirmPocket:
                Image(systemName: "iphone")
                    .font(.system(size: 64))
                    .foregroundStyle(DS.accent)
                Text("Phone goes in your \(pocketName) pocket")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("Hold it in your hand for now — pocket it at the last step.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Ready") { beginCapture(attempt: 1) }
                    .buttonStyle(.borderedProminent)
                Button("Skip calibration") { finishDegraded() }
                    .font(.callout)

            case .capturing(let attempt, let progress):
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .scaleEffect(2)
                Text("Stand still on your board — 5 seconds")
                    .font(.title2.bold())
                if attempt > 1 {
                    Text("Hold still a sec, trying again (\(attempt)/3)")
                        .foregroundStyle(DS.warnYellow)
                }

            case .pocketIt:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(DS.confirmGreen)
                Text("Pocket it and push off 🤙")
                    .font(.title.bold())
                Text("Capture starts automatically.")
                    .foregroundStyle(.secondary)

            case .degraded:
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundStyle(DS.warnYellow)
                Text("Stance stats off this sesh")
                    .font(.title2.bold())
                Text("Couldn't get a clean baseline. Everything else still tracks.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Let's go") { finishDegraded() }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding(24)
        .onDisappear { captureTask?.cancel() }
    }

    private var pocketName: String {
        switch model.defaultPocket {
        case .frontLeft: "front left"
        case .frontRight: "front right"
        case .backLeft: "back left"
        case .backRight: "back right"
        }
    }

    /// Captures 5 s of motion, computes gravity/attitude means and the FR-21 variance gate.
    private func beginCapture(attempt: Int) {
        step = .capturing(attempt: attempt, progress: 0)
        captureTask = Task {
            let capture = CoreMotionCapture(sampleRate: 50, armedMode: true)
            guard let feed = try? await capture.start() else {
                await capture.stop()
                step = .degraded
                return
            }
            var frames = [MotionFrame]()
            let needed = 250  // 5 s @ 50 Hz
            for await frame in feed.motion {
                frames.append(frame)
                if frames.count % 12 == 0 {
                    step = .capturing(
                        attempt: attempt, progress: Double(frames.count) / Double(needed))
                }
                if frames.count >= needed || Task.isCancelled { break }
            }
            await capture.stop()
            guard !Task.isCancelled else { return }

            var g = SIMD3<Float>.zero
            for f in frames { g += f.gravity }
            g /= Float(max(frames.count, 1))
            let mags = frames.map { $0.userAccel.shredLength }
            let mean = mags.reduce(0, +) / Float(max(mags.count, 1))
            let variance =
                mags.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) }
                / Float(max(mags.count, 1))

            let tuning = DetectionTuning()
            if variance <= tuning.calibrationStillMaxVariance, frames.count >= needed / 2 {
                result = CalibrationRecord(
                    pocket: model.defaultPocket, declaredStance: model.defaultStance,
                    baselineAttitude: frames[frames.count / 2].attitude, baselineGravity: g,
                    stillVariance: variance, quality: .good)
                step = .pocketIt
                try? await Task.sleep(for: .seconds(3))
                await model.calibrationFinished(result)
            } else if attempt < 3 {
                beginCapture(attempt: attempt + 1)
            } else {
                step = .degraded
            }
        }
    }

    private func finishDegraded() {
        captureTask?.cancel()
        Task { await model.calibrationFinished(nil) }
    }
}
#endif
