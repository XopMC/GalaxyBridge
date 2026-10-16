# Production audit

This audit records fresh checks of the supported Direct release scope on an
S24 Ultra running Android 16. Source tests and a successful build do not certify
all phones, networks, applications, or a zero-latency experience.

## Verified fixes

| Area | Defect and resulting behavior | Evidence |
| --- | --- | --- |
| Clipboard occurrences | Copying A again after a local Mac change was lost; GBC2 carries individual copy timestamps and injection origins | Hardware reproduction fails with GBC1 and passes with GBC2; fragmented-protocol regression |
| Phone images | The shell resolver returned FileNotFoundException for accessible image URIs; a dedicated resolver acquires and releases provider leases correctly | Synthetic PNG exact-byte round trip; actual Samsung Gallery Copy to clipboard screenshot arrives on Mac |
| Clipboard origins | A first-observed copy retaining old extras could be mistaken for an injection | Require matching digest and platform-owned shell/Helper writer attribution; first-observed foreign-source and unavailable-attribution regression tests |
| Clipboard races | A slow foreground image decode could overwrite a newer text/sensitive clip | Revision-fenced Android regression tests |
| Clipboard load | Unchanged images were repeatedly read, encoded and hashed | 172 unchanged polls require one payload read; new copies bypass the cache; failed reads retry after a bounded delay |
| Mac images | NSImage serialization expanded PNG into TIFF on the UI thread | Preserve original PNG bytes; invalid/oversized inputs leave the pasteboard unchanged |
| Notifications | Unbounded subscriber queues could retain icon payloads; dropped removals could survive reconnect | Bounded queues fail the exact transport; ordered full snapshots reconcile UI, cache and persisted native deliveries |
| Notification cleanup | Authorization and native-add callbacks could resurrect stale notifications | Deterministic callback-race and per-device reconciliation tests |
| Notification content | Only collapsed title/text extras were extracted | Expanded text, inbox and conversation extraction tests; opaque custom content retains its notification and receives neutral UI copy |
| Devices | Saved offline peers disappeared from the removal UI | Saved paired rows remain removable; 322 route/identity assertions |
| First pairing | Bonjour's willSet notification made the model read the previous discovery snapshot | Notify after committing the snapshot; actual publisher regression and clean S24 pairing connect without restarting either app |
| Android identity | Concurrent first access could create different keys or device IDs | Process-wide synchronization, synchronous ID persistence and five concurrent/persistence regressions; existing IDs are retained |
| Quit | Waiting for protected Downloads access could prevent termination indefinitely | Independent ten-second cleanup deadline; hanging-work/late-completion regressions and normal installed-app exit check |
| Disconnected mirror | A removed device row left a blank borderless window without a visible close control | Full-size dark unavailable state with a close button bound to its own hosting window; visually verified that closing it keeps the main window open |
| Catalog refresh | Refresh replaced useful tiles with an empty loading panel; obsolete route completion could strand loading | Preserve tiles, serialize requests, reject obsolete results and reload after a USB/Wi-Fi route change |
| QUIC launch | Native ADB child lacked the owned key directory and private server endpoint, causing SIGABRT | Child launch uses the same explicit environment/endpoint as regular ADB; real private-server regression and on-device producer start |
| QUIC temporary files | Retired sessions left native executables and producer JARs on the phone | Exact session-owned paths are removed after physical retirement; partial-launch rollback tests and an S24 open/close check (two files while running, zero after close) |
| Guidance | Direct screen instructions described the Companion capture flow; camera setup promised a virtual webcam | Distribution-specific screen/audio copy and phone-camera preview wording across shipping languages |

## Hardware checks

- Pairing via the normal QR/deep-link flow, catalog icons and refresh, an independent
  Android Settings window, mouse clicks and scrolling were visually exercised.
- Text A/B/A and synthetic PNG synchronization passed over Wireless ADB. A real
  1440 x 3120 screenshot copied in Samsung Gallery reached the Mac in the background.
  No Share action or custom input method is required.
- A synthetic notification appeared on Mac; dismissing it on Mac removed it on Android.
- A 104448-byte synthetic Mac-to-phone file transfer passed SHA-256 verification.
- A recorded MOV decoded successfully at 886 x 1920 with an AAC audio track.
  A five-second synthetic phone tone yielded nonzero decoded PCM in the recording.
- Phone-camera preview entered streaming state and stopped cleanly. Camera
  frame receipt does not validate the separately deferred virtual webcam.
- USB was available for setup and regression work; Wi-Fi-only selection isolates the
  actual transport without changing the phone's USB debugging setting.
- The final DMG was mounted, its Applications link and nested signatures verified,
  and its app installed in Applications. The final signed APK was installed and
  paired again; the Mac showed one device and restored the catalog after reconnect.
  A further clean Helper setup on the final app connected and loaded the catalog
  without restarting either application.

## Wireless timing

The baseline uses the public Wireless ADB profile: H.264, maximum 1920 pixels,
60 fps target and 6 Mbps video. In continuous motion, the largest observed gap was
264.5 ms at socket receipt and 266.7 ms at presentation. Decoder callbacks stayed
below 4.7 ms, and 98.1% of receive-to-main-actor hops completed within 1 ms.
Seven controlled clicks measured 84–176 ms from input dispatch to a changed visible
frame. These measurements establish a baseline; they do not establish a smoothness
improvement or guarantee performance on another network.

A phone Wi-Fi low-latency-lock experiment did not improve this run and was not
promoted. The existing QUIC design remains intact. A 120.6-second experimental QUIC run
after the ADB child fix presented 6094 frames, with a maximum 875 ms presentation
gap and a 6.55-second first frame. It is not an improvement over the baseline,
and is not promoted as the public default.

Matching the existing Wireless ADB AVC constant-bitrate setting, without
changing 6 Mbps / 1920 / 60 fps / one-second IDR, improved the next experimental
QUIC run: 58.76 distinct frames/s over 100.4 seconds after startup, versus
53.39 previously; maximum presentation gap 225 ms versus 875 ms. Eight visible
input responses measured 109–218 ms versus 131–537 ms. First frame remained
5.12 seconds. These sequential S24 measurements justify retaining this small
profile correction, not a general no-lag claim or QUIC default promotion. Experimental QUIC and the
public Wireless ADB route must be evaluated separately.

### Follow-up Wireless ADB endurance check

The source-built 0.1.1 Direct executable was copied to an Internal QA identity
to select only the Wireless ADB alias while the USB cable remained attached.
The video producer's live ADB command used that wireless endpoint. The public
H.264 profile was retained, with QUIC and the experimental Wi-Fi lock disabled.
Normal packaged installation and pairing were checked separately above.

- Continuous motion ran for **331.19 seconds** without a disconnect. There were
  16867 distinct presentation intervals, about **51.27 frames/s** after the first
  frame at 2.207 seconds. Maximum receive/presentation gaps were **201.3/233.3 ms**;
  decoder callback latency stayed below 4.46 ms. Occasional visible pauses remain.
- Thirty-one process samples over 300 seconds measured **140.9–153.6 MiB RSS**,
  ending at 152.2 MiB, and 11.7–22.1% CPU. Memory settled after warmup in this
  sample; this does not establish absence of leaks over hours. Diagnostics were on.
- A subsequent static response fixture received all **12 controlled clicks**.
  Input-to-visible-change latency was **85.0–193.8 ms**, with no expired probes
  or control failures. The coarse p95 histogram bucket was at most 250 ms; twelve
  samples do not establish a population percentile or a hard latency bound.
- After explicitly disconnecting and reconnecting the same Wireless ADB alias,
  the still-open mirror resumed and accepted another click. The transport was
  restored manually; automatic recovery across network roaming is still unproven.

## Remaining acceptance work

- Finish phone-to-Mac transfer after granting the standard Downloads permission.
  The installed public app also awaits this OS permission; the queued synthetic
  transfer is not counted as a successful acceptance check.
- Expand the measured motion/input checks to additional networks and longer runs.
- Repeat hardware checks after any relevant source change; abrupt process death
  and an unreachable phone can still leave that session's temporary files behind.
- Independent clean-Mac installation, long-duration and multi-network/device matrix
  testing remain separate release acceptance tasks.

## Scope and privacy

Only the authorized S24 Ultra is used. Private logs, images and timing artifacts
stay in the ignored build directory. Synthetic device files are removed after
verification. Full SMS and the Apple-provisioned virtual webcam remain previously
agreed future work. No personal fixtures or hardware identifiers belong in Git.
