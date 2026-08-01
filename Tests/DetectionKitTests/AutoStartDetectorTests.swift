import Foundation
import Testing

@testable import DetectionKit
import ShredCore
import SynthKit

private func runDetector(
    _ stream: AutoStartScenarios.Stream, config: AutoStartConfig = AutoStartConfig()
) -> (detections: [AutoStartDetection], pushCount: Int) {
    let d = AutoStartDetector(config: config)
    var detections = [AutoStartDetection]()
    var pushes = 0
    for f in stream.frames {
        let out = d.push(motion: f)
        if out.registeredPushTime != nil { pushes += 1 }
        if let det = out.detection { detections.append(det) }
    }
    return (detections, pushes)
}

@Suite struct AutoStartPositiveTests {
    @Test func detectsSteadyPushingAndBackdatesToFirstPush() {
        let stream = AutoStartScenarios.skatePushing(seed: 1, pushes: 6)
        let (detections, _) = runDetector(stream)
        #expect(detections.count == 1)
        guard let det = detections.first else { return }
        #expect(det.pushCount >= 4)
        #expect(det.confidence >= 0.72)
        // Backdating: within 400 ms of the true first push center (FR: timer starts at
        // push 1, not push 4).
        #expect(abs(det.firstPushTime - stream.truePushTimes[0]) < 0.4)
        // Confirmed no earlier than the 4th push.
        #expect(det.confirmedTime >= stream.truePushTimes[3] - 0.4)
        // Cadence ≈ 60/1.1 ≈ 55 ppm.
        #expect(abs(det.estimatedPushesPerMinute - 54.5) < 12)
    }

    @Test func placementIndependentAcrossRandomOrientations() {
        for seed in UInt64(10)...14 {
            var rng = SplitMix64(seed: seed)
            let attitude = AutoStartScenarios.makeAttitude(&rng)
            let stream = AutoStartScenarios.skatePushing(
                seed: seed, pushes: 6, attitude: attitude)
            let (detections, _) = runDetector(stream)
            #expect(detections.count == 1, "orientation seed \(seed) failed to detect")
        }
    }

    @Test func gentleCruisingPushesStillDetect() {
        let stream = AutoStartScenarios.skatePushing(
            seed: 2, pushes: 7, interval: 1.5, peakG: 0.24)
        let (detections, _) = runDetector(stream)
        #expect(detections.count == 1)
    }

    @Test func fastAggressivePushesStillDetect() {
        let stream = AutoStartScenarios.skatePushing(
            seed: 3, pushes: 6, interval: 0.6, peakG: 0.5)
        let (detections, _) = runDetector(stream)
        #expect(detections.count == 1)
    }

    @Test func doubleBumpPushesCountOncePerPush() {
        let stream = AutoStartScenarios.skatePushing(seed: 4, pushes: 5, doubleBump: true)
        let (detections, _) = runDetector(stream)
        #expect(detections.count == 1)
        guard let det = detections.first else { return }
        // 5 physical pushes; refractory + min-interval merging must not double-count.
        #expect(det.pushCount <= 5 + 1)
    }

    @Test func detectionFiresExactlyOnceUntilReset() {
        let stream = AutoStartScenarios.skatePushing(seed: 5, pushes: 12)
        let d = AutoStartDetector()
        var count = 0
        for f in stream.frames where d.push(motion: f).detection != nil {
            count += 1
        }
        #expect(count == 1)
    }

    @Test func resetRearmsDetection() {
        let stream = AutoStartScenarios.skatePushing(seed: 6, pushes: 6)
        let d = AutoStartDetector()
        var count = 0
        for f in stream.frames where d.push(motion: f).detection != nil {
            count += 1
        }
        d.reset()
        for f in stream.frames where d.push(motion: f).detection != nil {
            count += 1
        }
        #expect(count == 2)
    }
}

@Suite struct AutoStartNegativeTests {
    @Test func walkingDoesNotStartASession() {
        let (detections, _) = runDetector(AutoStartScenarios.walking(seed: 20))
        #expect(detections.isEmpty)
    }

    @Test func joggingDoesNotStartASession() {
        let (detections, _) = runDetector(AutoStartScenarios.jogging(seed: 21))
        #expect(detections.isEmpty)
    }

    @Test func carRideDoesNotStartASession() {
        let (detections, _) = runDetector(AutoStartScenarios.carRide(seed: 22))
        #expect(detections.isEmpty)
    }

    @Test func handFumbleDoesNotStartASession() {
        let (detections, _) = runDetector(AutoStartScenarios.handFumble(seed: 23))
        #expect(detections.isEmpty)
    }

    @Test func negativesHoldAcrossOrientations() {
        for seed in UInt64(30)...33 {
            var rng = SplitMix64(seed: seed)
            let att = AutoStartScenarios.makeAttitude(&rng)
            #expect(
                runDetector(AutoStartScenarios.walking(seed: seed, attitude: att))
                    .detections.isEmpty)
            #expect(
                runDetector(AutoStartScenarios.jogging(seed: seed, attitude: att))
                    .detections.isEmpty)
        }
    }

    @Test func brokenRhythmDoesNotConfirm() {
        // 3 pushes, a long gap, 3 pushes — never 4 consistent in one run.
        let a = AutoStartScenarios.skatePushing(seed: 40, pushes: 3)
        let gapFrames = AutoStartScenarios.walking(seed: 41, duration: 8).frames
        let b = AutoStartScenarios.skatePushing(seed: 42, pushes: 3)
        let d = AutoStartDetector()
        var detections = 0
        var t = 50.0
        for source in [a.frames, gapFrames, b.frames] {
            for var f in source {
                t += 0.02
                f.sensorTime = t  // restitch clocks into one stream
                if d.push(motion: f).detection != nil { detections += 1 }
            }
        }
        #expect(detections == 0)
    }
}
