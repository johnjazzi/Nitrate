import Testing

struct StartupSplashTimingTests {
    @Test func lateTicksSkipFramesWithoutCatchUpBursts() {
        var schedule = StartupSplashFrameSchedule(start: 100)
        #expect(abs(schedule.nextDeadline - (100 + 1.0 / 24)) < 0.000001)
        schedule.didDeliver(at: 100.15)
        #expect(schedule.nextDeadline >= 100.15 + 1.0 / 24)
        #expect(schedule.nextDeadline < 100.15 + 2.0 / 24)
        var timing = StartupSplashTiming()
        timing.setActive(true, at: 100)
        timing.advance(to: 100.15)
        #expect(timing.frameIndex == 3)
    }

    @Test func deadlinesNeverReplayMissedTicksOrExceedFrameRate() {
        var schedule = StartupSplashFrameSchedule(start: 0)
        var previousDelivery = 0.0
        for tick in 0..<240 {
            let delivery = schedule.nextDeadline + (tick.isMultiple(of: 7) ? 0.17 : 0.0001)
            #expect(delivery - previousDelivery >= 1.0 / 24 - 0.000001)
            schedule.didDeliver(at: delivery)
            #expect(schedule.nextDeadline > delivery)
            previousDelivery = delivery
        }
    }

    @Test func resumedScheduleDoesNotReplayInactiveDeadlines() {
        var timing = StartupSplashTiming(isPreview: true)
        timing.setActive(true, at: 0)
        timing.setActive(false, at: 0.5)
        timing.setActive(true, at: 100)
        let schedule = StartupSplashFrameSchedule(start: 100)
        #expect(schedule.nextDeadline > 100)
        #expect(timing.frameIndex == 12)
        timing.advance(to: schedule.nextDeadline)
        #expect(abs(timing.elapsed - (0.5 + 1.0 / 24)) < 0.000001)
        #expect(!timing.isFinished)
    }

    @Test func quantizesAtTwentyFourFramesPerSecond() {
        var timing = StartupSplashTiming()
        timing.setActive(true, at: 0)
        timing.advance(to: 1.0 / 24 - 0.000001)
        #expect(timing.frameIndex == 0)
        timing.advance(to: 1.0 / 24)
        #expect(timing.frameIndex == 1)
        timing.advance(to: 1.999)
        #expect(timing.frameIndex == 47)
        timing.advance(to: 2)
        #expect(timing.frameIndex == 0)
    }

    @Test func completesOneCycleThenFades() {
        var timing = StartupSplashTiming()
        timing.setActive(true, at: 0)
        timing.advance(to: 2)
        #expect(!timing.isFinished)
        #expect(timing.opacity == 1)
        timing.advance(to: 2.125)
        #expect(timing.opacity == 0.5)
        #expect(!timing.isFinished)
        timing.advance(to: 2.25)
        #expect(timing.isFinished)
        #expect(timing.opacity == 0)
        timing.advance(to: 20)
        #expect(timing.opacity == 0)
    }

    @Test func previewWrapsWithoutFadingOrFinishing() {
        var timing = StartupSplashTiming(isPreview: true)
        timing.setActive(true, at: 0)
        for cycle in 1...100 {
            timing.advance(to: Double(cycle) * 2)
            #expect(timing.frameIndex == 0)
            #expect(timing.rotationDegrees == 0)
            #expect(timing.opacity == 1)
            #expect(!timing.isFinished)
        }
    }

    @Test func rotationUsesTheSameQuantizedFrameAsGrain() {
        var timing = StartupSplashTiming()
        timing.setActive(true, at: 0)
        timing.advance(to: 1)
        #expect(timing.frameIndex == 24)
        #expect(timing.rotationDegrees == 180)
        timing.advance(to: 1.999)
        #expect(timing.rotationDegrees == 352.5)
        timing.advance(to: 2)
        #expect(timing.rotationDegrees == 360)
        timing.advance(to: 2.125)
        #expect(timing.rotationDegrees == 360)
    }

    @Test func inactiveTimeDoesNotAdvanceCycleOrFade() {
        var timing = StartupSplashTiming()
        timing.setActive(true, at: 0)
        timing.setActive(false, at: 1)
        timing.advance(to: 50)
        #expect(timing.elapsed == 1)
        timing.setActive(true, at: 100)
        timing.advance(to: 101.125)
        #expect(timing.elapsed == 2.125)
        #expect(timing.opacity == 0.5)
        timing.setActive(false, at: 101.125)
        timing.setActive(true, at: 200)
        #expect(timing.opacity == 0.5)
        timing.advance(to: 200.125)
        #expect(timing.isFinished)
    }

    @Test func inactiveClockStartsOnlyWhenActivated() {
        var timing = StartupSplashTiming()
        timing.advance(to: 100)
        #expect(timing.elapsed == 0)
        #expect(timing.frameIndex == 0)
        #expect(timing.opacity == 1)
        timing.setActive(true, at: 100)
        timing.setActive(true, at: 101)
        #expect(timing.elapsed == 1)
    }

    @Test func olderTimestampsCannotDoubleCountTime() {
        var timing = StartupSplashTiming()
        timing.setActive(true, at: 100)
        timing.advance(to: 101)
        timing.advance(to: 100.5)
        timing.advance(to: 101)
        #expect(timing.elapsed == 1)
    }
}
