import Foundation
import Testing

@testable import OurWhisper

@Suite("Update schedule")
struct UpdateScheduleTests {
    private let release = UpdateChecker.Release(
        version: "9.9.9",
        title: "9.9.9",
        notes: "",
        url: URL(string: "https://github.com/grozoww/our-whisper/releases/tag/v9.9.9")!,
        publishedAt: nil,
        dmg: nil,
        checksums: nil
    )

    @Test("A check that worked waits a whole interval")
    func waitsAfterSuccess() {
        #expect(UpdateSchedule.delay(after: .upToDate(checkedAt: Date())) == UpdateSchedule.interval)
        #expect(UpdateSchedule.delay(after: .available(release)) == UpdateSchedule.interval)
        #expect(UpdateSchedule.delay(after: .idle) == UpdateSchedule.interval)
    }

    @Test("A check that failed is asked again soon")
    func retriesAfterFailure() {
        // Waking from sleep is when a check comes due and when Wi-Fi is least likely to be back.
        // Waiting a whole interval after that would leave the Mac unchecked for the best part of
        // a day.
        let delay = UpdateSchedule.delay(after: .failed("The Internet connection appears to be offline."))
        #expect(delay == UpdateSchedule.retryInterval)
        #expect(delay < UpdateSchedule.interval)
    }

    @Test("Even the retry stays far under GitHub's limit for unauthenticated callers")
    func staysUnderRateLimit() {
        // 60 an hour per address, shared by everyone behind the same router. Whoever shortens the
        // retry should be reading this number, not finding out from a 403.
        let perHour = 3600 / UpdateSchedule.retryInterval.components.seconds
        #expect(perHour <= 6)
    }
}
