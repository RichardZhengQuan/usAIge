# Remote usage endpoint

The usAIge iOS app reads quota data from user-configured HTTPS endpoints. This
keeps provider credentials and provider-specific API logic on infrastructure the
user controls; the iOS app only receives normalized limit data.

## Request

usAIge sends an HTTPS `GET` request with these headers:

```http
Accept: application/json
Authorization: Bearer <token>
```

`Authorization` is omitted when the tool has no saved token. The token is saved
in the iOS Keychain and is never written to the widget cache.

## Response

Return HTTP `200` and a JSON body in this shape:

```json
{
  "schemaVersion": 1,
  "limits": [
    {
      "id": "five-hour",
      "name": "5-hour limit",
      "usedPercent": 42,
      "resetAt": "2026-07-14T12:00:00Z",
      "windowMinutes": 300,
      "plan": "Team",
      "secondaryWindow": {
        "usedPercent": 18,
        "resetAt": "2026-07-20T00:00:00Z",
        "windowMinutes": 10080
      }
    }
  ]
}
```

`remainingPercent` may be supplied instead of `usedPercent`. Percentages must
fall within `0...100`; malformed values are rejected so they cannot overwrite a
good cached snapshot. `resetAt`, `windowMinutes`, `plan`, and
`secondaryWindow` are optional. A response with no valid limits is rejected so
that a bad endpoint cannot silently replace good cached data.

`schemaVersion` is optional and currently supports version `1`. Unknown
top-level metadata is ignored; the app uses the name and endpoint configured by
the user on the device. Response bodies are capped at 1 MiB and oversized
responses are rejected before decoding.

## Caching and refresh timing

The app fetches immediately when a connection is tested, when it becomes
active, and when the user pulls to refresh. Successful normalized snapshots are
written to the App Group cache for the widget. Tokens are not included in that
cache.

The app also requests background refresh opportunities using the configured
minimum interval. iOS decides the actual execution time based on battery,
usage, network, and system policy, so neither the app nor its widget claims an
exact refresh guarantee. The widget displays the cached update time whenever
the data may be stale.

## Security recommendations

- Use HTTPS. The app rejects URL user info, query parameters, and fragments so
  credentials cannot bypass Keychain storage.
- Use a stable final URL. The app does not follow redirects, so bearer tokens
  cannot be forwarded to another origin.
- Issue a read-only, revocable token scoped only to normalized quota data.
- Avoid returning provider credentials, cookies, prompts, or account content.
- Return `401` or `403` when a token is invalid and `429` with a meaningful
  response when your endpoint is rate limited.
