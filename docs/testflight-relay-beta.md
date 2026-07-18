# TestFlight relay beta checklist

- Enable App Groups and Push Notifications for `com.richardq.usaige` and its widget.
- Configure the production APNs Team ID, Key ID, private `.p8` key, and topic in the Sites deployment; never commit the key.
- Apply the D1 relay migration before accepting pairing requests.
- Verify two physical iPhones can claim separate codes from one Mac and receive the same limits.
- Revoke one iPhone from Mac Settings and confirm its next read returns unauthorized while the other remains connected.
- Quit or disconnect the Mac network and confirm iPhone, widget, and Watch keep the last snapshot with an honest stale timestamp.
- Use **Disconnect All** and confirm the channel, devices, pairing codes, APNs tokens, and latest snapshot are deleted.
- Test foreground refresh separately from silent push; background delivery is best-effort and must not be described as real-time.
