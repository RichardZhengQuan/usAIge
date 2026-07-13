import Foundation
@testable import UsageHUD

enum Fixtures {
    static let codexSnapshot = QuotaSnapshot(
        id: "codex",
        displayName: "Codex 5-hour",
        usedPercent: 25,
        remainingPercent: 75,
        resetAt: Date(timeIntervalSince1970: 1_800_003_600),
        windowDurationMinutes: 300,
        planType: "plus",
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        secondaryWindow: QuotaWindowSnapshot(
            usedPercent: 33,
            remainingPercent: 67,
            resetAt: Date(timeIntervalSince1970: 1_800_086_400),
            windowDurationMinutes: 10_080
        )
    )

    static let multiBucketRateLimits: JSONValue = .object([
        "rateLimits": .object([
            "limitId": .string("codex"),
            "limitName": .string("Codex 5-hour"),
            "primary": .object([
                "usedPercent": .number(25),
                "windowDurationMins": .number(300),
                "resetsAt": .number(1_800_003_600),
            ]),
        ]),
        "rateLimitsByLimitId": .object([
            "codex": .object([
                "limitId": .string("codex"),
                "limitName": .string("Codex 5-hour"),
                "primary": .object([
                    "usedPercent": .number(25),
                    "windowDurationMins": .number(300),
                    "resetsAt": .number(1_800_003_600),
                ]),
                "secondary": .object([
                    "usedPercent": .number(33),
                    "windowDurationMins": .number(10_080),
                    "resetsAt": .number(1_800_086_400),
                ]),
            ]),
            "codex_other": .object([
                "limitId": .string("codex_other"),
                "limitName": .string("Codex weekly"),
                "primary": .object([
                    "usedPercent": .number(42),
                    "windowDurationMins": .number(10_080),
                    "resetsAt": .number(1_800_086_400),
                ]),
                "secondary": .object([
                    "usedPercent": .number(20),
                    "windowDurationMins": .number(10_080),
                    "resetsAt": .number(1_800_172_800),
                ]),
            ]),
        ]),
    ])

    static let singleBucketRateLimits: JSONValue = .object([
        "rateLimits": .object([
            "limitId": .string("codex"),
            "primary": .object([
                "usedPercent": .number(10),
                "windowDurationMins": .number(300),
                "resetsAt": .number(1_800_003_600),
            ]),
            "secondary": .object([
                "usedPercent": .number(40),
                "windowDurationMins": .number(10_080),
                "resetsAt": .number(1_800_086_400),
            ]),
        ]),
    ])
}
