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
| QUIC media intake | A ready large access unit paid a service wait for each 8 KiB read | A real preloaded 25,602-byte IDR changes from four read turns to one; larger/fragmented input and original deadlines remain bounded and byte-exact |
| QUIC gesture release | UP discarded the latest queued MOVE, including when DOWN had not finished writing | Exact stock-byte regressions preserve MOVE-before-UP, partial DOWN, CANCEL and the original 40 ms motion expiry |
| QUIC pacing | Early ciphertext generation retained a long FIFO behind a future pacing deadline | Bounded three-packet/~2 ms lookahead preserves committed packets; authenticated loopback delivery, reliable fairness and 6 Mbps payload throughput tests |
| Static video refresh | A temporarily unavailable Metal drawable could lose the only changed frame’s redraw request | Three bounded visible-surface retries, latest-frame coalescing and clear/detach cancellation regressions |
| Wireless ADB flow control | The owned server did not request Android's negotiated delayed-ACK capability | Enable ADB Burst Mode on the private server and its clients; actual server/phone capability intersection, USB input and an unread 8 MiB stream plus independent controls verified |
| Trackpad direction | Precise scrolling compensated deltas that AppKit had already adjusted to the user's preference | Eight actual scrollWheel cases cover both axes, signs and inversion flags; axis lock, dead zone, momentum and release rules remain intact |
| Android LAN connection | Companion transport unnecessarily requested Apple peer-to-peer discovery | LAN TLS/TCP parameters retain interface choice, TCP_NODELAY and keepalive without requesting Apple peer-to-peer; no isolated latency gain claimed |
| QUIC diagnostics | Metadata and decoded frames both contributed to one actor queue counter | Separate metadata accounting; hardware run reports zero queue imbalance and invalid timestamps |
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
- Phone-to-Mac reception passed after choosing Downloads through the app’s folder
  chooser and restarting the app. Sending that received 1568-byte neutral file
  back to Android preserved its original SHA-256. Both phone copies and the Mac
  fixture were removed afterward. This is source-app evidence; final packaging
  validation is recorded separately.
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

### Prioritized Wi-Fi correction

The normal installed public app was tested with its existing S24 pairing. The
USB host transport was detached, leaving the phone's debugging settings intact;
the live producer used the Wireless ADB endpoint. The H.264 1920-max / 60 fps
target / 6 Mbps profile was unchanged. The owned private ADB server now enables
**Burst Mode**, negotiated only when both peers support `delayed_ack`.

| Sequential motion run | Duration | Distinct presentation fps | Maximum receive / presentation gap |
| --- | --- | --- | --- |
| Before Burst Mode | 257.54 s | 51.11 | 306.39 / 316.67 ms |
| With Burst Mode | 93.37 s | 54.76 | 120.25 / 125.00 ms |

All twelve subsequent static-response clicks arrived: dispatch-to-visible change
was **82.9–215.5 ms**, with no control failures or expired probes. Holding an
8 MiB ADB stdout stream unread for 42 seconds did not block four independent
visible clicks. After reattaching USB, three further clicks arrived correctly.
These are sequential measurements of unequal duration on one network; they do
not establish a hard latency bound or eliminate radio/network jitter. Router
round-trip spikes of about 80–90 ms were also observed. No resolution, bitrate,
frame-rate target or declared function was removed.

A complete 19.95-second on-device Perfetto trace, with no trace-buffer loss,
matched twelve input responses. Median phone event-to-captured-frame time was
26.94 ms, captured-frame-to-encoded-output 23.86 ms, and host receipt-to-visible
presentation 25.80 ms. The remaining transport/handoff budget varied from
13.95 to 106.84 ms. Long codec dequeue waits alone were not treated as encoder
CPU stalls. Private traces, phone identities and screenshots are excluded from Git.

The experimental QUIC path also retains its architecture: bounded media intake,
MOVE-before-UP ordering, pacing lookahead and Metal redraw recovery have focused
regressions. A 103.79-second S24 run presented 58.09 distinct fps with a 200 ms
maximum presentation gap and zero diagnostic queue imbalance. It remains opt-in;
its measurements are not substituted for the public Wireless ADB results.

### Final package and regression checks

The updated DMG was mounted and its Applications link and nested ad-hoc
signatures verified. Mach-O code before the packaging signature matches the
source app used for timing; the installed executable matches the DMG exactly.
The installed package reconnected to the existing S24 pairing and displayed the
phone over Wireless ADB with USB detached at the host. Both scroll directions
were checked visually in the main mirror and a separate Android Settings window;
a direct mouse swipe and navigation clicks worked. That Wi-Fi upload retained its preceding APK. The subsequent acceptance update
below rebuilds both APK and DMG.

Fresh checks passed: **136 Swift tests in 15 suites**, the actual AppKit input
mapping spec, bounded Metal redraw recovery, Downloads scope persistence,
owned-ADB Burst negotiation, four native ingestion regressions, 175 native media
checks and the four pacing-horizon regressions plus related transport gates.
The publication scanner passed 928 source files; all eleven language catalogs
per platform passed key coverage. This does not replace independent hardware,
linguistic or clean-Mac acceptance.

## Display privacy and functional acceptance update

Fresh source-app checks, followed by installing the packaged app from its DMG.
The packaged app also displayed Settings and accepted a mouse swipe over Wi-Fi
with the physical display OFF; closing the mirror restored ON. Its nested
signatures and Applications link passed, and the installed executable matches
the DMG. The signed APK updated the existing Helper without replacing pairing:

| Area | Fresh evidence | Limits |
| --- | --- | --- |
| Physical display | Default enabled; primary mirror receives clicks while SurfaceFlinger reports physical OFF; Settings and Clock share one owner; closing only one keeps OFF; closing the last restores ON; disabling restores the previous mode | Panel power control, not Android keyguard locking; no PIN bypass |
| Failure recovery | Killing only the verified session-owned server restores the awake panel; UI changes to failure; explicit Retry hides it again; unique JAR and forward ownership checks preserve shared/unrelated resources | An unreachable phone prevents immediate remote reconciliation; no continuous hardware-button wake monitoring claim |
| Route migration | Active USB mirror resumes over verified Wireless ADB after host detach; clicks arrive; reattach returns to USB and clicks work | One S24/network; not a roaming or multi-phone matrix |
| App windows | Settings and Clock simultaneously; landscape/portrait resize and mapped Stop/Reset clicks; closing one preserves the other and display lease | Arbitrary third-party app layouts are not certified |
| Replies | Real synthetic RemoteInput gets exact Unicode once; invalidated PendingIntent reports failure and retains draft; explicit retry succeeds; offline Send preserves draft | Android acceptance is not service delivery; OS Notification Center inline UI unavailable to automation, covered by actual-entrypoint/inert-transport tests instead |
| Notification groups | Empty redundant summary suppressed while distinct/actionable content remains; unchanged ranking updates avoid repeated icon conversion | OEM/custom notification layouts need wider coverage |
| Image clipboard | Neutral phone PNG pasted in Preview; a distinct copied Preview PNG pasted visibly on Android with exact receipt hash; original Mac clipboard restored | Fresh Mac screenshot creation could not be exercised through available UI automation; actual Samsung Gallery screenshot transfer was verified in the earlier checks above |
| Files | Fresh first-selection 87,808-byte file passes after the macOS access metadata change; real Android file-picker send back matches SHA-256; live 512 MiB transfer cancelled after 24 MiB with no destination partial | Other providers/filesystems require their own matrix |
| File history | Final signed APK normal UI removes only our two completed QA receipts; original and published files are separate | Active/cancellation-fenced entries cannot be forgotten |
| Camera | Actual front-camera image; main/front requests; Stop clears preview, reopen works; accurate preview-only UI | No Apple-provisioned virtual webcam in Direct; every FPS/resolution/reconnect combination has not been hardware certified |
| Other UI | Russian system language, default-on toggle, About 0.1.1, setup feature list, SMS notice and cancel-safe removal confirmation inspected | No destructive re-pairing of the user's live device; independent clean Mac still outstanding |

The new reply protocol is additive and capability-negotiated. Legacy peers keep
unconfirmed drafts rather than claiming success. Pending replies and their timers
are bounded; revision and session fences protect edits and reconnects. No
background retry silently resends a reply.

Full Swift validation passed **136 tests / 15 suites**. Final Android DirectDebug
and InternalDebug passed **278 / 282 tests**, with the companion-core suite also
passing. Focused ownership, route-handoff, notification, camera policy and file
integrity checks passed. Eleven catalogs per platform passed key coverage (307
Mac UI keys, three permission keys, 110 Android keys). Build success is kept
separate from the hardware limits above.

## Remaining acceptance work

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
