# Input response fixture

A disposable, permission-free Android activity for developer diagnostics. It has
no launcher entry, account data or network access and is never bundled with the
Helper. Remove `com.xopmc.galaxybridge.qa.gestureresponse` after testing.

The Canvas contains neutral rows and an optional GBM1 click marker. Launch with a
fresh nonzero 32-bit `gb_marker_nonce` long extra; launch the Mac with the same
`--primary-input-marker-nonce=<decimal>` plus `--primary-media-diagnostics`.
Ordinary application behavior is unchanged when these options are absent.

Each trial requires exclusive input: no phone touches, other control clients,
scrolling or gestures. Close previous capture owners, restart this activity with
a fresh nonce and counter zero, then open a new mirror generation. Wait for
`input_marker_state=ready` before clicks. A nonce identifies the trial, not the
source of a touch; external touches can invalidate causal attribution even when
a counter matches. Reject the whole trial if it reports `invalidated`, if capture
owners overlap, or if independent Android input trace coverage is incomplete.

GBM1 uses 12 bytes: magic, big-endian nonce, big-endian ACTION_DOWN counter and
CRC-16/CCITT-FALSE. Its 96 cells align with the existing 24×24 luma sample grid.
Only generic virtual-finger DOWN controls advance expected counters. A decoded
frame proves only its exact ordinal; coalesced earlier responses remain unproven.
No image or nonce is written to the diagnostic log.

Run the host Swift/Java wire and matching checks with
`sh scripts/test-macos-input-marker.sh` using a supported JDK 21. Build the activity
with the normal Android SDK tools and a disposable test signing key. Do not sign
this fixture with a distribution key or include its APK in a release.
