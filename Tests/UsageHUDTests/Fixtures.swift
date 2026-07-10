import Foundation
@testable import UsageHUD

enum Fixtures {
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
            ]),
            "codex_other": .object([
                "limitId": .string("codex_other"),
                "limitName": .string("Codex weekly"),
                "primary": .object([
                    "usedPercent": .number(42),
                    "windowDurationMins": .number(10_080),
                    "resetsAt": .number(1_800_086_400),
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
        ]),
    ])
}
