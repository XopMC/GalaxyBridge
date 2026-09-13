#ifndef GALAXYBRIDGE_QUIC_BACKEND_H
#define GALAXYBRIDGE_QUIC_BACKEND_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
enum {
  GB_OK = 0,
  GB_EMPTY = 1,
  GB_PROTOCOL = 101,
  GB_CAPACITY = 102,
  GB_DEADLINE = 103,
  GB_CLOCK = 104,
  GB_AUTHENTICATION = 105,
  GB_IO = 106,
  GB_RETIRED = 107,
  GB_UNSUPPORTED = 108,
  GB_WRONG_THREAD = 109,
  GB_INVALID_HANDLE = 110,
  GB_CLEANUP = 111,
  GB_CLIPBOARD_ACK_MISSING_UNKNOWN_PASTE_OUTCOME = 112,
  GB_CODEC = 113,
  GB_UNRECOVERABLE_VIDEO_GAP = 114,
  GB_CONNECT_TIMEOUT = 115,
  GB_PEER_IDLE = 116,
  GB_RELIABLE_STALL = 117,
  GB_CLEANUP_PENDING = 118,
  /* Valid current kind5 media-only policy results; not generic errors. */
  GB_MEDIA_PRESSURE = 119,
  GB_MEDIA_EXPIRED = 120,
  GB_MEDIA_SKIPPED_DEPENDENT = 121
};
typedef struct {
  uint32_t abi, size;
  uint64_t reserved[2];
} GbHeader;
typedef struct {
  const uint8_t *data;
  size_t length;
} GbSlice;
typedef struct {
  GbHeader h;
  uint32_t track, state, reason, epoch, config, attempt;
  uint64_t revision, episode, next_deadline_ns, admitted_sequence;
  uint64_t declined, skipped, admitted_input_dropped, output_dropped;
  uint32_t output_pressure, reserved0;
} GbMediaHealth;
uint32_t gb_backend_media_health(uint64_t owner, uint32_t track, GbMediaHealth *out);
uint32_t gb_backend_media_retry(uint64_t owner, uint64_t expected_episode);
/* Pressure=1, Expired=2. Success declines but DOES NOT consume the event.
 * event_release remains required; duplicate/committed/nonmedia decline rejects. */
uint32_t gb_backend_media_decline(uint64_t owner, uint64_t event, uint32_t reason);
typedef struct {
  GbHeader h;
  uint64_t generation, target_token;
  uint32_t scid, display_id;
  uint8_t capture_kind, enabled;
  uint16_t reserved0;
  uint8_t sidecar_sha[32];
  GbSlice peer_ip, program;
  const GbSlice *args;
  uint32_t argc, reserved1;
} GbConfig;
typedef struct {
  GbHeader h;
  uint32_t phase, cleanup, forced, terminal;
  uint64_t now_ns;
  /* Sticky original 2s deadline failure, independent of physical cleanup. */
  uint32_t cleanup_failed;
} GbPoll;
typedef struct {
  GbHeader h;
  uint32_t kind, reserved;
  uint64_t received_ns;
  GbSlice bytes;
} GbInput;
typedef struct {
  GbHeader h;
  uint64_t effective_ns, reverse_ns, clipboard_ns;
} GbDeviceEligibility;
typedef struct {
  GbHeader h;
  uint32_t kind, code;
  uint64_t handle, ticket, ordinal;
  uint32_t track, epoch, config, record_kind;
  uint64_t pts, deadline_ns;
  GbSlice bytes, configuration;
  /* Media-only immutable G1 identity, identical in next_event/media_check.
   * sequence is the original GQM1 sequence (metadata: next AU boundary);
   * flags are unmodified GQM1 flags, never inferred from callback counts.
   * ordinal is exclusively the reverse-device ordinal. receiver_owner is
   * OutputLease.owner, NOT a C registry handle. Other fields are exact G1
   * Context values. Session identity must not be logged or passed in argv. */
  uint64_t sequence, receiver_owner, generation, target_token;
  uint32_t scid, display_id, flags, capture_kind, enabled;
  uint8_t session[32];
} GbEvent;
/* No event handle or pointer is consumed. Original immutable context must
 * match this owner; old source publications are ignored, future ones reject.
 * Called on the C owner thread from one coalesced per-track native snapshot. */
uint32_t gb_backend_media_native_status(uint64_t owner, const GbEvent *identity,
    uint64_t input_lost_through, uint64_t input_drops, uint64_t output_sequence, uint32_t pressure, uint64_t output_drops);
/* Headers must be {abi=1,size=sizeof(the struct),reserved={0,0}}.
 * Caller buffers must be readable for the declared lengths during the call.
 * Only event/copy release may run on a foreign destructor thread.
 * Event pointers remain immutable and valid until event_release, even when
 * owner retirement makes media_check/commit fail. Copy reservation precedes
 * native allocation; copy_release follows destruction of that actual copy.
 * Retirement is not cancellation of accepted remote reliable bytes.
 * Per owner,128 total handles include 96 ordinary,16 additional semantic
 * UP/CANCEL/key-up/UHID-destroy or stock-ACK slots,16 terminal/completion.
 * Release classes still pass original G1 validation/deadlines; reserves do
 * not admit malformed input or renew expiry. Copies use ordinary capacity.
 * Completion reservations transfer into results rather than double charge.
 */
uint32_t gb_backend_create(const GbConfig *, uint64_t *owner);
uint32_t gb_backend_poll(uint64_t owner, GbPoll *);
uint32_t gb_backend_now_ns(uint64_t owner, uint64_t *);
uint32_t gb_backend_next_wakeup_ns(uint64_t owner, uint64_t *);
/* Input kind1=complete GQM1 Critical,2=GQM1 MOVE,3=original bulk stock command.
 * For MOVE the status remains GB_OK and ticket is an admission disposition:
 * 0 queued,2 replaced,3 stale,4 expired. It is not an application completion. */
uint32_t gb_backend_submit(uint64_t owner, const GbInput *, uint64_t *ticket);
/* Event kind1 Ready,2 Media,3 original device event,4 bulk result,
 *5 G1 transaction result,6 terminal,7 exact-owned producer display status.
 * Kind7 code1 assignment: track=width,epoch=height,config=density,display_id=ID
 * (positive Int32). code2 conflict/code3 ended have those four scalars zero.
 * Kind7 generation,target_token,scid,capture_kind,enabled,session preserve the
 * original context; no raw stdout is exported. Every nonzero handle is released.
 * */
uint32_t gb_backend_next_event(uint64_t owner, GbEvent *);
uint32_t gb_backend_media_check(uint64_t owner, uint64_t handle, GbEvent *);
/* Same checked identity view; valid expired AU returns120 and remains releasable. */
uint32_t gb_backend_media_admission_check(uint64_t owner, uint64_t handle, GbEvent *);
uint32_t gb_backend_media_copy_reserve(uint64_t owner, uint64_t handle, uint64_t *copy);
uint32_t gb_backend_media_commit(uint64_t owner, uint64_t handle);
/* Native AU payload-only admission, owner-thread only. The caller first owns
 * an actual independently copied buffer under its bounded native admission.
 * Validate exact ticket/lease, uncommitted freshness and storage capacity,
 * then atomically commit+move one of8 transfer credits into at most64 retained
 * storage tickets. Bytes/configuration/owner remain charged until copy_release.
 * No new allocation or deadline. Duplicate/foreign/type errors reject. Capacity
 * prevalidation leaves the source UNCOMMITTED and both handles charged, no ACK.
 * Metadata/composite/legacy callers continue using media_commit unchanged. */
uint32_t gb_backend_native_copy_commit(uint64_t owner, uint64_t handle, uint64_t copy);
uint32_t gb_backend_device_commit(uint64_t owner, uint64_t handle);
/* Read-only, owner-thread, BEFORE device_commit. Original cutoffs, not a new
 * receipt: effective=min(reverse, nonzero clipboard). clipboard=0 means no
 * matching original SET watch. At >=clipboard classify112, otherwise at
 * >=reverse classify103, including112 precedence when both expired. A caller
 * committing before an actor hop must retain storage and enforce these SAME
 * cutoffs through ordered callback admission/completion, including while the
 * actor never runs; commit does not prove a keyboard/paste effect occurred. */
uint32_t gb_backend_device_eligibility(uint64_t owner, uint64_t handle,
                                      GbDeviceEligibility *);
uint32_t gb_backend_copy_reserve(uint64_t owner, uint64_t handle,
                                 uint64_t *copy);
/* One actual bytes payload copy, not configuration pointer copying. Charges
 * that payload's pool bytes and pins its real configuration until copy_release.
 * AU bytes pointers are borrowed ONLY until event_release: finish synchronous
 * copying and a fresh check before releasing that event. Native AU admission
 * uses native_copy_commit; metadata/legacy admission uses media_commit.
 * The ticket owns the independent copy charge, NOT the original AU pointer.
 * Metadata payload tickets continue pinning their original immutable storage.
 * A config payload copy adds byte/slot charge without another fictitious version.
 * AU payload copies use a SEPARATE hard8 in-transfer allowance, sharing the SAME16MiB
 * aggregate bytes with original/composite AU storage. Original/composite AU
 * admission stays8 slots; no extra network/reassembly slots.
 * native_copy_commit moves AU credit to a separate hard64 retained-storage
 * allowance without releasing any bytes/configuration/owner. Metadata payload
 * copies still use the original metadata slots/bytes. Existing composite
 * copy_reserve above retains its prior semantics. */
uint32_t gb_backend_payload_copy_reserve(uint64_t owner, uint64_t handle,
                                         uint64_t *copy);
uint32_t gb_backend_event_release(uint64_t owner, uint64_t handle);
uint32_t gb_backend_copy_release(uint64_t owner, uint64_t copy);
uint32_t gb_backend_retire(uint64_t owner);
/* GB_CLEANUP_PENDING (118): incomplete/not retired, retains owner for service.
 * GB_OK: settled on time, consumes owner. GB_CLEANUP (111): physically settled
 * but missed original cleanup cutoff, ALSO consumes owner. Do not retry either
 * consumed outcome. Retained event/copy handles remain releasable and keep
 * storage/the old owner slot charged until final release. Poll phase5 means
 * physically settled, NOT successful timed cleanup: inspect cleanup_failed. */
uint32_t gb_backend_destroy(uint64_t owner);
#ifdef GB_BACKEND_QA
/* Eight caller-writable u64 scalars: receiver original/composite AU slots and
 * aggregate AU bytes (including new copies), metadata
 * slots/bytes, held payload-copy AU slots/bytes, metadata slots/bytes.
 * Owner-thread only, read-only, absent from production artifacts. */
uint32_t gb_backend_qa_pools(uint64_t owner, uint64_t values[8]);
/* Two scalars: AU transfer-in-progress and transferred storage tickets.
 * qa_pools AU copy count continues counting BOTH domains and all real bytes. */
uint32_t gb_backend_qa_transfer_usage(uint64_t owner, uint64_t values[2]);
/* Prepared-fixture stock effect only. Pop at most64 observations from exact
 * child stderr: ordinal, direction(1 command/2 complete response), length,
 * child-local monotonic elapsed ns, SHA256 as four BE u64. GB_EMPTY if none.
 * Fixed160B line/64-entry capture, no raw command bytes or production export. */
uint32_t gb_backend_qa_control_observation(uint64_t owner, uint64_t values[8]);
/* Available only in explicitly built QA artifacts. Configure before first
 * poll. Whole duration1..30000ms starts at owner creation, never at readiness.
 * mode0 clean(sequence/index0),1 one selected fragment,2 whole selected AU.
 * Both fixture roles wait only for a valid existing observation, not low RTT.
 * Original media deadlines and deliberate-drop accounting remain unchanged. */
uint32_t gb_backend_qa_component(uint64_t owner, uint32_t duration_ms,
                                 uint32_t mode, uint64_t sequence,
                                 uint32_t index);
uint32_t gb_backend_qa_dropped(uint64_t owner, uint64_t *);
/* Deterministic test boundary: cleanup=0 sets nondecreasing owner-local ns;
 * cleanup=1 sets elapsed ns from an ALREADY STARTED original cleanup origin.
 * Does not fake transport or child exit. Absent from production artifacts. */
uint32_t gb_backend_qa_time(uint64_t owner, uint64_t ns, uint32_t cleanup);
#endif
#ifdef __cplusplus
}
#endif
#endif
