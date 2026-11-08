import Testing
@testable import UsageHUD

@Suite("Weather redraw admission")
struct CruiseWeatherDrawAdmissionTests {
    @Test func aFinalPausedRedrawSurvivesABusyGPUWithoutGrowingAQueue() {
        let admission = CruiseWeatherDrawAdmission()
        #expect(admission.request())
        #expect(admission.request())
        // A storm animation can fill both slots just before Pause, Reduce
        // Motion, or a final resize asks for the newest still frame.
        for _ in 0..<1_000 { #expect(!admission.request()) }
        #expect(admission.complete(), "The first completion must retry the coalesced final redraw")
        #expect(admission.request(), "The pending still frame must fit the released GPU slot")
        #expect(!admission.complete(), "The other old frame must not cause another retry")
        #expect(!admission.complete(), "Completing the still frame must leave no perpetual work")
        #expect(!admission.complete())
        #expect(admission.request())
        #expect(admission.request())
        #expect(!admission.request(), "The two-frame limit must remain in force after recovery")
    }

    @Test func aFailedEncodingReturnsItsSlotAndANewerAdmittedDrawSupersedesThePendingOne() {
        let admission = CruiseWeatherDrawAdmission()
        #expect(admission.request())
        admission.abandon()
        #expect(!admission.complete(), "A failed draw without other GPU work must not schedule retries")
        #expect(admission.request())
        #expect(admission.request())
        #expect(!admission.request())
        #expect(admission.complete())
        // A normal view draw may get here before the queued main-thread
        // retry. It already renders the latest state and clears old demand.
        #expect(admission.request())
        #expect(!admission.complete())
        #expect(!admission.complete())
        #expect(!admission.complete(), "No extra release may invent a redraw")
    }

    @Test func aRetryThatCannotEncodeWaitsForAnotherRealCompletionWithoutSpinning() {
        let admission = CruiseWeatherDrawAdmission()
        #expect(admission.request())
        #expect(admission.request())
        #expect(!admission.request())
        #expect(admission.complete(), "One busy frame releases the first retry")
        #expect(admission.request())
        // The resumed attempt finds no drawable/pass/encoder. The second
        // original GPU frame still provides a real future completion.
        admission.abandon()
        #expect(admission.complete(), "The remaining real completion must preserve that failed latest redraw")
        #expect(admission.request())
        // If this attempt also cannot encode, there are no GPU frames left;
        // nothing should immediately retry it or create a polling loop.
        admission.abandon()
        #expect(!admission.complete())
        #expect(!admission.complete())
        #expect(admission.request(), "A later normal visibility draw can still render the latest configuration")
        #expect(!admission.complete())
    }
}
