#include "galaxybridge_quic_backend.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#define HEADER(T) ((GbHeader){1, sizeof(T), {0, 0}})
/* QA-only symbol; it is absent from production artifacts. */
extern uint32_t gb_backend_qa_time(uint64_t, uint64_t, uint32_t);
extern uint32_t gb_backend_qa_transfer_usage(uint64_t, uint64_t *);
extern uint32_t gb_backend_qa_pools(uint64_t, uint64_t *);
static GbSlice slice(const char *s) {
  return (GbSlice){(const uint8_t *)s, strlen(s)};
}
static void *wrong_thread(void *p) {
  GbPoll poll = {.h = HEADER(GbPoll)};
  assert(gb_backend_poll(*(uint64_t *)p, &poll) == GB_WRONG_THREAD);
  return NULL;
}
static void be32(uint8_t *b, uint32_t n) {
  for (int i = 3; i >= 0; i--) {
    b[i] = (uint8_t)n;
    n >>= 8;
  }
}
static void be64(uint8_t *b, uint64_t n) {
  for (int i = 7; i >= 0; i--) {
    b[i] = (uint8_t)n;
    n >>= 8;
  }
}
static uint64_t command_generation = 1, command_receipt = 0;
static uint32_t command(uint64_t owner, uint64_t sequence, int release,
                        uint64_t *ticket) {
  uint8_t bytes[114] = {0};
  memcpy(bytes, "GQM1", 4);
  bytes[4] = 8;
  be64(bytes + 8, command_generation);
  be32(bytes + 16, 1);
  be64(bytes + 24, sequence);
  bytes[47] = 1;
  uint32_t body = release ? 50 : 37;
  be32(bytes + 40, body);
  bytes[49] = (uint8_t)body;
  be32(bytes + 56, 500000);
  bytes[64] = release ? 4 : 9;
  be32(bytes + 96, release ? 14 : 1);
  bytes[100] = release ? 0 : 5;
  bytes[101] = release ? 1 : 0;
  uint64_t now = 0;
  assert(gb_backend_now_ns(owner, &now) == GB_OK);
  GbInput input = {.h = HEADER(GbInput),
                   .kind = 1,
                   .received_ns = command_receipt ? command_receipt : now,
                   .bytes = {bytes, 64 + body}};
  return gb_backend_submit(owner, &input, ticket);
}
static uint64_t complete(uint64_t owner, uint64_t ticket) {
  for (int turn = 0; turn < 500; turn++) {
    GbPoll poll = {.h = HEADER(GbPoll)};
    assert(gb_backend_poll(owner, &poll) == GB_OK);
    GbEvent event = {.h = HEADER(GbEvent)};
    uint32_t s = gb_backend_next_event(owner, &event);
    if (s == GB_OK) {
      assert(event.kind == 5 && event.ticket == ticket && event.code == 0);
      return event.handle;
    }
    assert(s == GB_EMPTY);
    usleep(1000);
  }
  assert(!"original 500ms transaction did not complete");
  return 0;
}
typedef struct {
  uint64_t owner, event, copy;
} Release;
static void *foreign_release(void *value) {
  Release *r = value;
  assert(gb_backend_event_release(r->owner, r->event) == GB_OK);
  assert(gb_backend_event_release(r->owner, r->event) == GB_INVALID_HANDLE);
  assert(gb_backend_copy_release(r->owner, r->copy) == GB_OK);
  assert(gb_backend_copy_release(r->owner, r->copy) == GB_INVALID_HANDLE);
  return NULL;
}
static void finish_owner(uint64_t owner) {
  assert(gb_backend_retire(owner) == GB_OK);
  for (int turn = 0; turn < 2000; turn++) {
    GbPoll p = {.h = HEADER(GbPoll)};
    uint32_t s = gb_backend_poll(owner, &p);
    assert(s == GB_RETIRED && !p.cleanup_failed);
    if (p.cleanup) {
      assert(gb_backend_destroy(owner) == GB_OK);
      return;
    }
    usleep(1000);
  }
  assert(!"cleanup did not settle");
}
static void fix1_boundaries(GbConfig config) {
  {
    GbSlice args[] = {slice("--test-child-stall")};
    config.args = args;
    uint64_t owner = 0;
    assert(gb_backend_create(&config, &owner) == GB_OK);
    assert(gb_backend_destroy(owner) == GB_CLEANUP_PENDING);
    assert(gb_backend_retire(owner) == GB_OK);
    assert(gb_backend_destroy(owner) == GB_CLEANUP_PENDING);
    assert(gb_backend_qa_time(owner, 2000000000ULL, 1) == GB_OK);
    int complete = 0;
    for (int i = 0; i < 1000; i++) {
      GbPoll p = {.h = HEADER(GbPoll)};
      assert(gb_backend_poll(owner, &p) == GB_CLEANUP);
      assert(p.cleanup_failed);
      if (p.cleanup) { complete = 1; break; }
      usleep(1000);
    }
    assert(complete && gb_backend_destroy(owner) == GB_CLEANUP);
    assert(gb_backend_destroy(owner) == GB_INVALID_HANDLE);
  }
  for (int delta = -1; delta <= 2; delta++) {
    /* delta2 also expires the ACK's separate residence budget: neither
     * deadline can hide the original clipboard failure or revive paste. */
    GbSlice args[] = {slice(delta == 2 ? "--test-peer" : "--test-peer-delayed-ack")};
    config.args = args;
    uint64_t owner = 0, received = 0, ack = 0;
    assert(gb_backend_create(&config, &owner) == GB_OK);
    int applied = 0;
    for (int turn = 0; turn < 3000 && !ack; turn++) {
      GbPoll p = {.h = HEADER(GbPoll)};
      assert(gb_backend_poll(owner, &p) == GB_OK);
      if (p.phase == 3 && !received) {
        assert(gb_backend_now_ns(owner, &received) == GB_OK);
        uint8_t clip[15] = {9};
        be64(clip + 1, 91); clip[13] = 1; clip[14] = 'x';
        GbInput input = {.h = HEADER(GbInput), .kind = 3,
                         .received_ns = received, .bytes = {clip, 15}};
        uint64_t ticket = 0;
        assert(gb_backend_submit(owner, &input, &ticket) == GB_OK && ticket);
      }
      for (;;) {
        GbEvent e = {.h = HEADER(GbEvent)};
        uint32_t s = gb_backend_next_event(owner, &e);
        if (s == GB_EMPTY) break;
        assert(s == GB_OK);
        if (e.kind == 2) assert(gb_backend_media_commit(owner, e.handle) == GB_OK);
        if (e.kind == 4) { assert(e.code == 0); applied = 1; }
        if (e.kind == 3) {
          assert(e.ordinal == 1 && e.bytes.length == 9 && e.bytes.data[8] == 91);
          ack = e.handle;
        } else assert(gb_backend_event_release(owner, e.handle) == GB_OK);
      }
      usleep(1000);
    }
    assert(ack && applied);
    GbDeviceEligibility eligibility = {.h = HEADER(GbDeviceEligibility)};
    assert(gb_backend_device_eligibility(owner, ack, &eligibility) == GB_OK);
    assert(eligibility.clipboard_ns == received + 2000000000ULL);
    assert(eligibility.effective_ns == (eligibility.clipboard_ns < eligibility.reverse_ns ? eligibility.clipboard_ns : eligibility.reverse_ns));
    assert(gb_backend_device_eligibility(owner, UINT64_MAX, &eligibility) == GB_INVALID_HANDLE);
    assert(gb_backend_device_eligibility(owner, ack, &eligibility) == GB_OK);
    assert(gb_backend_qa_time(owner, received + 2000000000ULL + delta, 0) == GB_OK);
    assert(gb_backend_device_commit(owner, ack) ==
           (delta < 0 ? GB_OK : GB_CLIPBOARD_ACK_MISSING_UNKNOWN_PASTE_OUTCOME));
    if (delta >= 0) {
      GbPoll p = {.h = HEADER(GbPoll)};
      assert(gb_backend_poll(owner, &p) == GB_RETIRED);
      assert(p.terminal == GB_CLIPBOARD_ACK_MISSING_UNKNOWN_PASTE_OUTCOME);
      assert(gb_backend_device_commit(owner, ack) == GB_RETIRED);
    }
    assert(gb_backend_event_release(owner, ack) == GB_OK);
    finish_owner(owner);
  }
  for (int delta = -1; delta <= 1; delta++) {
    GbSlice args[] = {slice("--test-peer-identity")};
    config.args = args;
    uint64_t owner = 0, copy = 0;
    assert(gb_backend_create(&config, &owner) == GB_OK);
    GbEvent held = {.h = HEADER(GbEvent)};
    uint64_t identity = 0;
    int packets = 0, configurations = 0;
    for (int turn = 0; turn < 2000 && packets < 2; turn++) {
      GbPoll p = {.h = HEADER(GbPoll)};
      assert(gb_backend_poll(owner, &p) == GB_OK);
      for (;;) {
        GbEvent e = {.h = HEADER(GbEvent)}, checked = {.h = HEADER(GbEvent)};
        uint32_t s = gb_backend_next_event(owner, &e);
        if (s == GB_EMPTY) break;
        assert(s == GB_OK);
        if (e.kind == 2) {
          assert(gb_backend_media_check(owner, e.handle, &checked) == GB_OK);
          assert(e.receiver_owner && e.generation == 1 && e.target_token == 9 &&
                 e.scid == 1 && e.display_id == 0 && e.enabled == 6 && e.capture_kind == 0);
          if (!identity) identity = e.receiver_owner;
          uint8_t any = 0;
          for (int i = 0; i < 32; i++) any |= e.session[i];
          assert(any != 0);
          assert(e.receiver_owner == identity && checked.receiver_owner == identity);
          assert(checked.sequence == e.sequence && checked.flags == e.flags &&
                 checked.epoch == e.epoch && checked.config == e.config &&
                 checked.pts == e.pts && memcmp(checked.session, e.session, 32) == 0);
          if (e.record_kind == 2) assert(gb_backend_copy_reserve(owner, e.handle, &copy) == GB_OK);
          if (e.record_kind == 4) {
            configurations++;
            assert(e.config == (uint32_t)configurations && e.epoch == 1 && e.track == 2);
            /* Metadata carries the next AU sequence, not the prior watermark. */
            assert(e.flags == 0 && e.sequence == (uint64_t)configurations);
            assert(e.bytes.length == 2 && e.bytes.data[0] == 0x11 && e.bytes.data[1] == 0x90);
          }
          if (e.record_kind == 5) {
            packets++;
            assert(e.sequence == (uint64_t)packets && e.flags == 2 && e.track == 2 &&
                   e.epoch == 1 && e.config == (uint32_t)packets && e.pts == (uint64_t)packets * 42);
            assert(e.bytes.length == 3 && e.bytes.data[0] == 0x21 &&
                   e.bytes.data[2] == (packets == 1 ? 0x55 : 0x66));
            if (packets == 2) {
              held = e;
            }
          }
          assert(gb_backend_media_commit(owner, e.handle) == GB_OK);
        }
        if (e.handle != held.handle) assert(gb_backend_event_release(owner, e.handle) == GB_OK);
      }
      usleep(1000);
    }
    assert(packets == 2 && configurations == 2);
    assert(gb_backend_retire(owner) == GB_OK);
    assert(gb_backend_qa_time(owner, 2000000000ULL + delta, 1) == GB_OK);
    int settled = 0;
    for (int turn = 0; turn < 1000; turn++) {
      GbPoll p = {.h = HEADER(GbPoll)};
      uint32_t s = gb_backend_poll(owner, &p);
      assert(s == (delta < 0 ? GB_RETIRED : GB_CLEANUP));
      assert(p.cleanup_failed == (uint32_t)(delta >= 0));
      if (p.cleanup) { assert(p.phase == 5); settled = 1; break; }
      /* Poll's incomplete observation is advisory; destroy could itself
       * observe a subsequent reap, so do not assert a stale snapshot. */
      usleep(1000);
    }
    assert(settled);
    assert(gb_backend_destroy(owner) == (delta < 0 ? GB_OK : GB_CLEANUP));
    /* Destroy consumed the backend even on failed timing. Immutable retained
     * storage/copy stays releasable; retrying destroy is never required. */
    assert(gb_backend_destroy(owner) == GB_RETIRED);
    assert(held.bytes.data[2] == 0x66);
    Release release = {owner, held.handle, copy};
    pthread_t thread;
    assert(pthread_create(&thread, NULL, foreign_release, &release) == 0);
    assert(pthread_join(thread, NULL) == 0);
    assert(gb_backend_destroy(owner) == GB_INVALID_HANDLE);
  }
  puts("C fix1: original ACK cutoff; immutable config/AU identity; cleanup timing versus settled/destroy ownership PASS");
}
static void native_transfer_boundaries(GbConfig config) {
  /* Main's preceding owner-quota case selects an EOF child. This independent
   * real-media case must explicitly select its authenticated media peer. */
  GbSlice args[] = {slice("--test-peer")}; config.args = args; config.argc = 1;
  uint64_t owner = 0, other = 0;
  assert(gb_backend_create(&config, &owner) == GB_OK);
  assert(gb_backend_create(&config, &other) == GB_OK);
  int done = 0;
  for (int turn = 0; turn < 2000 && !done; turn++) {
    GbPoll p = {.h = HEADER(GbPoll)};
    assert(gb_backend_poll(owner, &p) == GB_OK);
    GbEvent e = {.h = HEADER(GbEvent)};
    while (gb_backend_next_event(owner, &e) == GB_OK) {
      if (e.kind == 2) {
        uint64_t copy = 0, composite = 0, counts[2] = {0}, before[8] = {0}, after[8] = {0};
        assert(gb_backend_payload_copy_reserve(owner, e.handle, &copy) == GB_OK);
        assert(gb_backend_native_copy_commit(other, e.handle, copy) == GB_INVALID_HANDLE);
        assert(gb_backend_native_copy_commit(owner, e.handle, UINT64_MAX) == GB_INVALID_HANDLE);
        if (e.record_kind == 5) {
          uint8_t *actual = malloc(e.bytes.length);
          assert(actual != NULL); memcpy(actual, e.bytes.data, e.bytes.length);
          assert(gb_backend_copy_reserve(owner, e.handle, &composite) == GB_OK);
          assert(gb_backend_native_copy_commit(owner, e.handle, composite) == GB_PROTOCOL);
          assert(gb_backend_copy_release(owner, composite) == GB_OK);
          assert(gb_backend_qa_transfer_usage(owner, counts) == GB_OK && counts[0] == 1 && counts[1] == 0);
          assert(gb_backend_qa_pools(owner, before) == GB_OK);
          assert(gb_backend_native_copy_commit(owner, e.handle, copy) == GB_OK);
          assert(gb_backend_qa_transfer_usage(owner, counts) == GB_OK && counts[0] == 0 && counts[1] == 1);
          assert(gb_backend_qa_pools(owner, after) == GB_OK && memcmp(before, after, sizeof(before)) == 0);
          assert(gb_backend_native_copy_commit(owner, e.handle, copy) == GB_PROTOCOL);
          assert(actual[0] == 0x21 && actual[2] == 0x55);
          assert(gb_backend_retire(owner) == GB_OK);
          assert(gb_backend_native_copy_commit(owner, e.handle, copy) == GB_RETIRED);
          assert(gb_backend_destroy(owner) == GB_CLEANUP_PENDING);
          free(actual);
          Release release = {owner, e.handle, copy}; pthread_t thread;
          assert(pthread_create(&thread, NULL, foreign_release, &release) == 0);
          assert(pthread_join(thread, NULL) == 0);
          done = 1; break;
        }
        assert(gb_backend_native_copy_commit(owner, e.handle, copy) == GB_PROTOCOL);
        assert(gb_backend_media_commit(owner, e.handle) == GB_OK);
        assert(gb_backend_copy_release(owner, copy) == GB_OK);
      }
      assert(gb_backend_event_release(owner, e.handle) == GB_OK);
      e = (GbEvent){.h = HEADER(GbEvent)};
    }
    if (!done) usleep(1000);
  }
  assert(done); finish_owner(owner); finish_owner(other);
  puts("C native transfer: actual copied bytes, atomic commit, exact ticket/type/owner, counts, foreign final release PASS");
}
static void media_expired_release_boundary(GbConfig config) {
  uint64_t owner=0; assert(gb_backend_create(&config,&owner)==GB_OK);
  int done=0;
  for (int turn=0;turn<2000 && !done;turn++) {
    GbPoll p={.h=HEADER(GbPoll)}; assert(gb_backend_poll(owner,&p)==GB_OK);
    GbEvent e={.h=HEADER(GbEvent)};
    while (gb_backend_next_event(owner,&e)==GB_OK) {
      if (e.kind==2 && e.record_kind==5) {
        assert(gb_backend_qa_time(owner,e.deadline_ns,0)==GB_OK);
        GbEvent checked={.h=HEADER(GbEvent)};
        uint32_t check=gb_backend_media_check(owner,e.handle,&checked);
        uint32_t release=gb_backend_event_release(owner,e.handle);
        fprintf(stderr,"C expired AU check=%u release=%u\n",check,release);
        assert(check!=GB_OK);
        assert(release==GB_OK);
        done=1;break;
      }
      if(e.kind==2) assert(gb_backend_media_commit(owner,e.handle)==GB_OK);
      assert(gb_backend_event_release(owner,e.handle)==GB_OK);
      e=(GbEvent){.h=HEADER(GbEvent)};
    }
    if(!done)usleep(1000);
  }
  assert(done); finish_owner(owner);
  puts("C expired uncommitted AU remains exactly-once releasable PASS");
}
static void media_decline_boundary(GbConfig config) {
  uint64_t owner=0,other=0; assert(gb_backend_create(&config,&owner)==GB_OK);assert(gb_backend_create(&config,&other)==GB_OK);
  int done=0;
  for(int turn=0;turn<2000 && !done;turn++) {
    GbPoll p={.h=HEADER(GbPoll)};assert(gb_backend_poll(owner,&p)==GB_OK);
    GbEvent e={.h=HEADER(GbEvent)};
    while(gb_backend_next_event(owner,&e)==GB_OK) {
      if(e.kind==2 && e.record_kind==5) {
        uint64_t copies[8]={0},extra=99,counts[2]={0};
        for(int i=0;i<8;i++)assert(gb_backend_media_copy_reserve(owner,e.handle,&copies[i])==GB_OK);
        assert(gb_backend_media_copy_reserve(owner,e.handle,&extra)==GB_MEDIA_PRESSURE && extra==0);
        assert(gb_backend_media_decline(other,e.handle,1)==GB_INVALID_HANDLE);
        assert(gb_backend_media_decline(owner,e.handle,2)==GB_PROTOCOL);
        assert(gb_backend_media_decline(owner,e.handle,1)==GB_OK);
        assert(gb_backend_media_decline(owner,e.handle,1)==GB_PROTOCOL);
        assert(gb_backend_native_copy_commit(owner,e.handle,copies[0])==GB_PROTOCOL);
        assert(gb_backend_event_release(owner,e.handle)==GB_OK);
        assert(gb_backend_event_release(owner,e.handle)==GB_INVALID_HANDLE);
        assert(gb_backend_qa_transfer_usage(owner,counts)==GB_OK && counts[0]==8 && counts[1]==0);
        GbMediaHealth health={.h=HEADER(GbMediaHealth)};
        assert(gb_backend_media_health(owner,2,&health)==GB_OK && health.state==3 && health.declined==1);
        p=(GbPoll){.h=HEADER(GbPoll)};assert(gb_backend_poll(owner,&p)==GB_OK);
        assert(gb_backend_retire(owner)==GB_OK);assert(gb_backend_destroy(owner)==GB_CLEANUP_PENDING);
        for(int i=0;i<8;i++)assert(gb_backend_copy_release(owner,copies[i])==GB_OK);
        done=1;break;
      }
      if(e.kind==2) {
        assert(gb_backend_media_decline(owner,e.handle,1)==GB_PROTOCOL);
        assert(gb_backend_media_commit(owner,e.handle)==GB_OK);
      }
      assert(gb_backend_event_release(owner,e.handle)==GB_OK);e=(GbEvent){.h=HEADER(GbEvent)};
    }
    if(!done)usleep(1000);
  }
  assert(done);finish_owner(owner);finish_owner(other);puts("C media decline/copy pressure/identity/final reference PASS");
}
static void submit_site_boundary(GbConfig config, int clock_error) {
  uint64_t owner=0,ticket=0;int ready=0;
  assert(gb_backend_create(&config,&owner)==GB_OK);
  for(int turn=0;turn<2000 && !ready;turn++) {
    GbPoll p={.h=HEADER(GbPoll)};assert(gb_backend_poll(owner,&p)==GB_OK);
    ready=p.phase==3;
    for(;;) {
      GbEvent e={.h=HEADER(GbEvent)};uint32_t s=gb_backend_next_event(owner,&e);
      if(s==GB_EMPTY)break;
      assert(s==GB_OK);
      if(e.kind==2)assert(gb_backend_media_commit(owner,e.handle)==GB_OK);
      if(e.handle)assert(gb_backend_event_release(owner,e.handle)==GB_OK);
    }
    usleep(1000);
  }
  assert(ready);
  if(clock_error)command_receipt=UINT64_MAX;
  uint32_t status=command(owner,clock_error ? 1:2,0,&ticket);
  fprintf(stderr,"qa-submit-site mode=%u status=%u ticket=%llu\n",clock_error,status,(unsigned long long)ticket);
  assert(status==(clock_error ? GB_CLOCK:GB_PROTOCOL) && ticket==0);
  command_receipt=0;
  assert(command(owner,1,0,&ticket)==GB_OK);
  int completed=0;
  for(int turn=0;turn<500 && !completed;turn++) {
    GbPoll p={.h=HEADER(GbPoll)};assert(gb_backend_poll(owner,&p)==GB_OK);
    for(;;) {
      GbEvent e={.h=HEADER(GbEvent)};uint32_t s=gb_backend_next_event(owner,&e);
      if(s==GB_EMPTY)break;
      assert(s==GB_OK);
      if(e.kind==2)assert(gb_backend_media_commit(owner,e.handle)==GB_OK);
      if(e.kind==5) {assert(e.ticket==ticket && e.code==0);completed=1;}
      if(e.handle)assert(gb_backend_event_release(owner,e.handle)==GB_OK);
    }
    usleep(1000);
  }
  assert(completed);
  finish_owner(owner);
}
int main(int argc, char **argv) {
  assert(argc == 2);
  GbSlice args[] = {slice("--test-peer")};
  GbConfig config = {.h = HEADER(GbConfig),
                     .generation = 1,
                     .target_token = 9,
                     .scid = 1,
                     .display_id = 0,
                     .enabled = 6,
                     .peer_ip = slice("127.0.0.1"),
                     .program = slice(argv[1]),
                     .args = args,
                     .argc = 1};
  memset(config.sidecar_sha, 4, 32);
  if(getenv("GB_PROTOCOL_SITE_ONLY")) {submit_site_boundary(config,0);submit_site_boundary(config,1);return 0;}
  if (getenv("GB_MEDIA_EXPIRED_ONLY")) { media_expired_release_boundary(config); return 0; }
  if (getenv("GB_MEDIA_POLICY_ONLY")) { media_expired_release_boundary(config); media_decline_boundary(config); return 0; }
  if (getenv("GB_NATIVE_TRANSFER_ONLY")) { native_transfer_boundaries(config); return 0; }
  if (getenv("GB_FIX1_ONLY")) { fix1_boundaries(config); return 0; }
  uint64_t invalid = 0;
  GbConfig bad = config;
  bad.h.abi = 2;
  assert(gb_backend_create(&bad, &invalid) == GB_PROTOCOL);
  bad = config;
  bad.h.size--;
  assert(gb_backend_create(&bad, &invalid) == GB_PROTOCOL);
  bad = config;
  bad.reserved1 = 1;
  assert(gb_backend_create(&bad, &invalid) == GB_PROTOCOL);
  bad = config;
  bad.generation = 0;
  assert(gb_backend_create(&bad, &invalid) == GB_PROTOCOL);
  uint64_t owner = 0;
  uint32_t status = gb_backend_create(&config, &owner);
  if (status != GB_OK) {
    fprintf(stderr, "C create status=%u\n", status);
    return 1;
  }
  assert(gb_backend_destroy(owner) == GB_CLEANUP_PENDING);
  pthread_t thread;
  assert(pthread_create(&thread, NULL, wrong_thread, &owner) == 0);
  assert(pthread_join(thread, NULL) == 0);
  GbEvent held = {.h = HEADER(GbEvent)};
  uint64_t copy = 0;
  int au = 0, ready = 0;
  uint8_t *foreign_copy = NULL;
  for (int turn = 0; turn < 3000 && !au; turn++) {
    GbPoll poll = {.h = HEADER(GbPoll)};
    assert(gb_backend_poll(owner, &poll) == GB_OK);
    ready |= poll.phase == 3;
    for (;;) {
      GbEvent event = {.h = HEADER(GbEvent)};
      status = gb_backend_next_event(owner, &event);
      if (status == GB_EMPTY)
        break;
      assert(status == GB_OK);
      if (event.kind == 2) {
        GbEvent checked = {.h = HEADER(GbEvent)};
        assert(gb_backend_media_check(owner, event.handle, &checked) == GB_OK);
        if (event.record_kind == 5) {
          assert(event.sequence == 1 && event.flags == 2);
          assert(event.receiver_owner != 0 && event.generation == 1 &&
                 event.scid == 1 && event.display_id == 0 &&
                 event.target_token == 9 && event.capture_kind == 0 && event.enabled == 6);
          assert(checked.sequence == event.sequence && checked.flags == event.flags &&
                 checked.receiver_owner == event.receiver_owner &&
                 memcmp(checked.session, event.session, 32) == 0);
          assert(event.pts == 42 && event.bytes.length == 3 &&
                 event.bytes.data[0] == 0x21);
          assert(gb_backend_copy_reserve(owner, event.handle, &copy) == GB_OK);
          foreign_copy =
              malloc(event.bytes.length + event.configuration.length);
          assert(foreign_copy != NULL);
          memcpy(foreign_copy, event.bytes.data, event.bytes.length);
          if (event.configuration.length)
            memcpy(foreign_copy + event.bytes.length, event.configuration.data,
                   event.configuration.length);
          held = event;
          au = 1;
        }
        assert(gb_backend_media_commit(owner, event.handle) == GB_OK);
      }
      if (event.handle != held.handle)
        assert(gb_backend_event_release(owner, event.handle) == GB_OK);
    }
    usleep(1000);
  }
  assert(ready && au);
  uint64_t handles[110], ticket = 0;
  for (uint64_t i = 0; i < 94; i++) {
    assert(command(owner, i + 1, 0, &ticket) == GB_OK);
    handles[i] = complete(owner, ticket);
  }
  assert(command(owner, 95, 0, &ticket) == GB_CAPACITY);
  command_generation = 2;
  assert(command(owner, 95, 1, &ticket) == GB_PROTOCOL);
  command_generation = 1;
  command_receipt = UINT64_MAX;
  assert(command(owner, 95, 1, &ticket) == GB_CLOCK);
  command_receipt = 0;
  for (uint64_t i = 0; i < 16; i++) {
    assert(command(owner, 95 + i, 1, &ticket) == GB_OK);
    handles[94 + i] = complete(owner, ticket);
  }
  assert(command(owner, 111, 1, &ticket) == GB_CAPACITY);
  assert(gb_backend_event_release(owner + 1, handles[0]) == GB_INVALID_HANDLE);
  assert(gb_backend_retire(owner) == GB_OK);
  GbEvent terminal = {.h = HEADER(GbEvent)};
  assert(gb_backend_next_event(owner, &terminal) == GB_OK &&
         terminal.kind == 6);
  assert(gb_backend_event_release(owner, terminal.handle) == GB_OK);
  for (int i = 0; i < 110; i++) {
    assert(gb_backend_event_release(owner, handles[i]) == GB_OK);
    assert(gb_backend_event_release(owner, handles[i]) == GB_INVALID_HANDLE);
  }
  assert(held.bytes.data[0] == 0x21);
  GbEvent checked = {.h = HEADER(GbEvent)};
  assert(gb_backend_media_check(owner, held.handle, &checked) == GB_RETIRED);
  int cleaned = 0;
  for (int turn = 0; turn < 2000; turn++) {
    GbPoll poll = {.h = HEADER(GbPoll)};
    status = gb_backend_poll(owner, &poll);
    assert(status == GB_RETIRED);
    if (poll.cleanup) {
      cleaned = 1;
      break;
    }
    usleep(1000);
  }
  assert(cleaned);
  assert(gb_backend_destroy(owner) == GB_OK);
  assert(held.bytes.data[2] == 0x55);
  GbSlice eof_args[] = {slice("--test-child-eof")};
  config.args = eof_args;
  uint64_t owners[16];
  for (int i = 0; i < 15; i++)
    assert(gb_backend_create(&config, &owners[i]) == GB_OK);
  GbConfig invalid_program = config;
  invalid_program.program = slice("/nonexistent/gb-owned-capacity-oracle");
  uint64_t rejected = 0;
  assert(gb_backend_create(&invalid_program, &rejected) == GB_CAPACITY &&
         rejected == 0);
  assert(foreign_copy[0] == 0x21 && foreign_copy[2] == 0x55);
  free(foreign_copy);
  Release release = {owner, held.handle, copy};
  assert(pthread_create(&thread, NULL, foreign_release, &release) == 0);
  assert(pthread_join(thread, NULL) == 0);
  assert(gb_backend_create(&config, &owners[15]) == GB_OK &&
         owners[15] != owner);
  assert(gb_backend_event_release(owners[15], held.handle) ==
         GB_INVALID_HANDLE);
  for (int i = 0; i < 16; i++)
    assert(gb_backend_retire(owners[i]) == GB_OK);
  int remaining = 16;
  int done[16] = {0};
  for (int turn = 0; turn < 2000 && remaining; turn++) {
    for (int i = 0; i < 16; i++)
      if (!done[i]) {
        GbPoll poll = {.h = HEADER(GbPoll)};
        assert(gb_backend_poll(owners[i], &poll) == GB_RETIRED);
        if (poll.cleanup) {
          assert(gb_backend_destroy(owners[i]) == GB_OK);
          done[i] = 1;
          remaining--;
        }
      }
    if (remaining)
      usleep(1000);
  }
  assert(remaining == 0);
  fix1_boundaries(config);
  native_transfer_boundaries(config);
  puts("C ABI: real paired completions, 96/112 reserves, terminal progress, "
       "16/17 owners, retained foreign release and exact cleanup PASS");
  return 0;
}
