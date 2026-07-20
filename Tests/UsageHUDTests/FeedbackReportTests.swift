import Foundation
import Testing
@testable import UsageHUD

@Test func feedbackRequiresNonWhitespaceContent() {
    var draft = FeedbackDraft()
    #expect(!draft.canSubmit)

    draft.content = "  \n "
    #expect(!draft.canSubmit)

    draft.content = "Please make the reset date clearer."
    #expect(draft.canSubmit)
}

@Test func feedbackSubmissionIncludesCompleteAppAndSystemContext() throws {
    let submittedAt = Date(timeIntervalSince1970: 1_800_000_100)
    let submission = FeedbackSubmission(
        content: "  Please make the reset date clearer.  ",
        platform: "macOS",
        systemVersion: "macOS 26.0 (25A123)",
        architecture: "arm64",
        locale: "en_SG",
        language: "en-SG",
        appVersion: "0.2.1",
        appBuild: "23",
        appBundleIdentifier: "com.richardzhengquan.usaige",
        submittedAt: submittedAt
    )

    #expect(submission.content == "Please make the reset date clearer.")
    #expect(submission.platform == "macOS")
    #expect(submission.systemVersion == "macOS 26.0 (25A123)")
    #expect(submission.architecture == "arm64")
    #expect(submission.locale == "en_SG")
    #expect(submission.language == "en-SG")
    #expect(submission.appVersion == "0.2.1")
    #expect(submission.appBuild == "23")
    #expect(submission.appBundleIdentifier == "com.richardzhengquan.usaige")
    #expect(submission.submittedAt == submittedAt)
}

@Test func feedbackSubmissionLimitsContentLength() {
    let submission = FeedbackSubmission(content: String(repeating: "a", count: 4_001))
    #expect(submission.content.count == FeedbackDraft.contentLimit)
}
