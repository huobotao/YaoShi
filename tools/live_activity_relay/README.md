# Private local Live Activity relay

This optional Mac process sends already-computed display snapshots to Apple APNs while the iPhone app is suspended. The Mac must remain awake and online; Apple may delay or throttle delivery, especially with priority 5 and under thermal/power pressure. This is not a guarantee of one update every 30 seconds. Never remove stale-state indication to conceal delivery gaps.

No service is enabled by adding these files. An APNs signing key, HTTPS endpoint trusted by iOS, and explicit device configuration are required. The signing key remains on the Mac. Only the display state and ActivityKit token are sent to Apple; source dose histories and notes are not accepted. The display includes health information, including last-dose amount/time already shown on the lock screen.

## Configure privately

Install requirements in an isolated Python environment. Create a mode-600 JSON config outside the repository with these keys:

- `environment`: `sandbox` for development-signed installs or `production` for distribution.
- `apnsKeyPath`, `apnsKeyID`, `apnsTeamID`: signing-key location and identifiers.
- `deviceSecrets`: map of local device aliases to distinct cryptographically random bearer secrets, at least 32 characters. Provision the matching secret to each phone; do not commit it.
- `statePath`: absolute private JSON state location, outside any repository or shared/synced folder.
- `bindHost`, `port`: default `127.0.0.1`, `8443`.
- `tlsCertPath`, `tlsKeyPath`: HTTPS certificate chain and private key. Required for any non-loopback listener. iPhone must trust its certificate through normal trust mechanisms. Do not bypass certificate validation.

Run `python3 relay.py --config /absolute/private/config.json`. A same-host reverse proxy may terminate trusted HTTPS in front of the loopback HTTP listener. Never expose a plaintext listener to the LAN or internet. Request access logs are disabled; do not add proxy logs containing identifiers, authorization, or bodies. Configure the service manager to restart the process if required, without logging private config contents.

## API contract

`PUT /v1/activities/{activityID}` with `Authorization: Bearer <device secret>` and JSON:

```json
{
  "generation": 1,
  "token": "hex-encoded-activity-token",
  "topic": "com.richardhuo.yaoshi.push-type.liveactivity",
  "environment": "sandbox",
  "expiresAt": 1800028800,
  "schedule": [
    {
      "at": 1800000000,
      "staleAt": 1800000060,
      "contentState": {
        "lastMg": 0, "phaseRaw": "none", "level": 0,
        "takenToday": 0, "skippedToday": false, "pillsLeft": 0,
        "refreshedAt": 821692800
      }
    }
  ]
}
```

The example is synthetic and the placeholder token is intentionally invalid. `at`, `staleAt`, `expiresAt` are integer Unix seconds; dates inside `contentState` use Swift Codable's default seconds since 2001. Schedule must be strictly ordered, <=961 entries, <=8 hours plus transmission tolerance. The service fixes the APNs topic/environment; client values cannot override them.

Generation increases per activity across retries, edits, rotation, and withdrawals. Exact duplicate requests are idempotent; lower/conflicting generations return 409. A fresh schedule replaces the previous one. Device identity comes solely from authentication. `DELETE` at the same URL with `{ "generation": 2 }` withdraws all future updates and removes the stored token/state. It does not itself end the on-device activity; the client ends that activity through ActivityKit.

Only the newest currently valid due entry is sent after sleep/outage. Permanent token errors remove the private payload; transient errors back off. State is atomically persisted mode 600 so restarts do not replay old snapshots. Generation tombstones last 24 hours; clients must not retry requests beyond the schedule validity. A single-process file lock prevents concurrent senders.

## Verification

`python3 -m unittest discover -s tools/live_activity_relay -p 'test_*.py' -v`

Tests use synthetic payloads and an injected fake sender. They do not prove live APNs acceptance, device delivery, locked-phone updates, or thermal behavior. Verify those separately before describing the original issue as fixed.

For device content readback, a fresh developer-launched app process may use `--yaoshi-activity-readback <unique-nonce>`. This branches before constructing Store and does not request, update, or end any Activity. Read the private `Library/Application Support/Diagnostics/live-activity-readback.json` through the authorized device tooling. Require the matching nonce and a fresh `capturedAtUnix`; a locked-device write can fail and leave an older file. An already running process ignores new launch arguments. This diagnostic launch has a blank screen and must be terminated after collection before normal use resumes. Do not use ordinary app startup as evidence of background delivery, because it publishes a local update.

The isolated simulator test proves the diagnostic path does not create records or initialize normal publishing. Its activity collection was empty, so real APNs-updated content still requires physical-device verification. Check both the readback timestamps/content and the actual lock-screen/Dynamic Island display. An APNs success response alone is not delivery proof.

## Readiness and operational checks

The following commands do not start a listener, install a service, create credentials, or send APNs requests:

```sh
python3 tools/live_activity_relay/operations.py check --config /absolute/private/config.json
python3 tools/live_activity_relay/operations.py check --config /absolute/private/config.json --client-config /absolute/private/phone-config.json
python3 tools/live_activity_relay/operations.py launchd --config /absolute/private/config.json --output /absolute/staging/relay.plist
```

`check` verifies HTTP/2 dependencies, private file permissions, local P-256 signing, certificate/key matching and validity dates, storage accessibility, and optionally matching phone authentication/environment. It reports check names and booleans only. It does not verify externally reachable HTTPS, certificate trust on iPhone, installed signing entitlements, APNs account authorization, or delivery. If the relay binds only to loopback behind a reverse proxy, verify the proxy's HTTPS separately. A missing `h2` dependency must be fixed by installing `requirements.txt` into the intended private environment.

The generated launchd plist references that Python interpreter, suppresses stdout/stderr, and uses a 30-second restart throttle. It is only a staged artifact; this command refuses direct writes into `LaunchAgents` or `LaunchDaemons` and does not overwrite an existing file. Installation and enabling are separate operations.

When explicitly enabled, the relay maintains a mode-600 status file at `statePath + ".status.json"`, or the optional distinct absolute `statusPath`. Read it without exposing tokens or health data:

```sh
python3 tools/live_activity_relay/operations.py status --config /absolute/private/config.json
```

Status includes process existence, a 30-second heartbeat (considered stale after 90 seconds), session start time, last APNs HTTP status, most recent successful APNs acceptance time, and session success/failure/storage-error counts. These counters restart with the process. APNs acceptance is not proof that the phone displayed the update. The status output never includes activity identifiers, tokens, display states, or server URLs.
