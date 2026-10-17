// Synthetic USB boundary for the real AOSP Read/Write/Open/Close bodies.
#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <future>
#include <iostream>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <vector>
using namespace std::chrono_literals;
struct FakeUSB { bool closed = false; };
using libusb_device_handle = FakeUSB;
constexpr int LIBUSB_ERROR_NO_DEVICE=-4, LIBUSB_ERROR_TIMEOUT=-7, LIBUSB_ERROR_OTHER=-99;
struct amessage { uint32_t command=0, arg0=0, arg1=0, data_length=0, data_check=0, magic=0; };
struct apacket { amessage msg; std::vector<unsigned char> payload; };
struct QuietLog { template<class T> QuietLog& operator<<(const T&) { return *this; } };
#define VLOG(x) QuietLog()
const char* command_to_string(uint32_t) { return "synthetic"; }
const char* libusb_error_name(int) { return "synthetic"; }
std::string StringPrintf(const char*, unsigned int) { return "endpoint"; }
struct Boundary {
 std::mutex mutex; std::condition_variable cv;
 bool entered=false, release=false, reading=false, freedDuringRead=false, unbounded=false;
 int mode=0, closed=0, nullCalls=0, calls=0, zlp=0; size_t position=0;
 std::vector<unsigned char> input, output;
} b;
int libusb_release_interface(FakeUSB*, int) { return 0; }
void libusb_close(FakeUSB* h) {
 std::lock_guard<std::mutex> l(b.mutex); b.freedDuringRead |= b.reading;
 if(h){h->closed=true; b.closed++;}
}
int libusb_clear_halt(FakeUSB* h, uint8_t endpoint) {
 std::unique_lock<std::mutex> l(b.mutex);
 if(b.mode==2 && endpoint==0x81) {
  b.reading=true;b.entered=true;b.cv.notify_all();
  b.cv.wait(l,[]{return b.release;});b.reading=false;
 }
 if(!h || h->closed){b.nullCalls++;return LIBUSB_ERROR_NO_DEVICE;}
 return 0;
}
int libusb_bulk_transfer(FakeUSB* h, uint8_t endpoint, unsigned char* bytes, int length,
                         int* transferred, unsigned int timeout) {
 std::unique_lock<std::mutex> l(b.mutex); b.calls++; b.unbounded |= timeout==0;
 *transferred=0;
 if(!h || h->closed){b.nullCalls++; return LIBUSB_ERROR_NO_DEVICE;}
 if(endpoint & 0x80) {
  if(b.mode==0){
   b.reading=true; b.entered=true; b.cv.notify_all();
   b.cv.wait(l,[]{return b.release;});
   b.reading=false;
   if(h->closed){b.nullCalls++;return LIBUSB_ERROR_NO_DEVICE;}
   return LIBUSB_ERROR_TIMEOUT;
  }
  if(b.position>=b.input.size()) return LIBUSB_ERROR_NO_DEVICE;
  int n=std::min<int>(length,std::min<size_t>(3,b.input.size()-b.position));
  std::memcpy(bytes,b.input.data()+b.position,n); b.position+=n; *transferred=n;
  return n<length ? LIBUSB_ERROR_TIMEOUT : 0;
 }
 if(length==0)b.zlp++;
 int n=b.mode==1 ? std::min(length,3) : length;
 b.output.insert(b.output.end(),bytes,bytes+n); *transferred=n;
 return n<length ? LIBUSB_ERROR_TIMEOUT : 0;
}
struct LibUsbDevice {
 FakeUSB fake;
 libusb_device_handle* device_handle_ = &fake;
 std::atomic<bool> interface_claimed_{false};
 std::mutex lifecycle_mutex_;
 std::shared_mutex handle_mutex_;
 std::atomic<bool> closing_{true};
 int interface_num_=0; uint8_t read_endpoint_=0x81,write_endpoint_=1; int zlp_mask_=63,out_endpoint_size_=64;
 std::string serial_="synthetic";
 bool openAllowed=true,claimAllowed=true;
 bool OpenDeviceHandle(){ if(!openAllowed)return false;device_handle_=&fake;fake.closed=false;return true; }
 bool ClaimInterface(){interface_claimed_=claimAllowed;return claimAllowed;}
 std::string GetSerial(){return serial_;}
 void ReleaseInterface(); void CloseDeviceHandle(); void ClearEndpoints();
 bool Open(); bool Close(); bool Read(apacket*); bool Write(apacket*);
 int BulkTransfer(uint8_t,unsigned char*,int,int*);
};
// ACTUAL_METHODS
void reset(int mode) {
 std::lock_guard<std::mutex> l(b.mutex);
 b.entered=b.release=b.reading=b.freedDuringRead=b.unbounded=false;
 b.mode=mode;b.closed=b.nullCalls=b.calls=b.zlp=0;b.position=0;b.input.clear();b.output.clear();
}
int main() {
 reset(0); LibUsbDevice d; assert(d.Open()); apacket packet;
 auto read=std::async(std::launch::async,[&]{return d.Read(&packet);});
 {std::unique_lock<std::mutex> l(b.mutex);assert(b.cv.wait_for(l,1s,[]{return b.entered;}));}
 apacket outgoing;outgoing.payload={1,2,3,4};outgoing.msg.data_length=4;
 auto write=std::async(std::launch::async,[&]{return d.Write(&outgoing);});
 bool parallelWrite=write.wait_for(500ms)==std::future_status::ready;
 std::promise<void> started;
 auto close=std::async(std::launch::async,[&]{started.set_value();return d.Close();});
 started.get_future().wait();
 bool heldUntilIOExit=close.wait_for(100ms)==std::future_status::timeout;
 {std::lock_guard<std::mutex> l(b.mutex);b.release=true;b.cv.notify_all();}
 assert(!read.get()); assert(write.get()); assert(close.get());
 assert(parallelWrite && "an idle read serialized an independent control write");
 assert(!b.unbounded && "Close cannot bound an indefinitely blocked USB transfer");
 assert(heldUntilIOExit && !b.freedDuringRead && b.nullCalls==0 && "Close freed the USB handle while an actual Read was still using it");
 int calls=b.calls; assert(!d.Read(&packet)); assert(!d.Write(&outgoing));
 assert(b.calls==calls && "retired handle admitted a later read/write");
 assert(d.Close() && b.closed==1 && "repeated close released a handle twice");
 reset(1); assert(d.Open());
 amessage header;header.command=0x1234;header.data_length=4;
 auto* first=reinterpret_cast<unsigned char*>(&header);b.input.assign(first,first+sizeof(header));b.input.insert(b.input.end(),{7,8,9,10});
 assert(d.Read(&packet) && "partial timeout lost an ADB header/payload");
 assert(packet.msg.command==header.command && packet.payload==std::vector<unsigned char>({7,8,9,10}));
 assert(d.Write(&packet));assert(b.output==b.input && "partial write replayed or dropped bytes");
 assert(d.Close());
 reset(1); assert(d.Open());
 apacket aligned;aligned.msg.data_length=64;aligned.payload.assign(64,0x55);
 assert(d.Write(&aligned) && b.zlp==1 && b.output.size()==sizeof(amessage)+64);
 assert(d.Close());
 reset(1);d.openAllowed=false;assert(!d.Open());
 assert(!d.Read(&packet) && !d.Write(&packet) && b.calls==0);assert(d.Close());
 d.openAllowed=true;d.claimAllowed=false;assert(!d.Open());
 assert(!d.Read(&packet) && !d.Write(&packet) && b.calls==0);assert(d.Close());
 d.claimAllowed=true;
 reset(2);assert(d.Open());
 auto clear=std::async(std::launch::async,[&]{d.ClearEndpoints();});
 {std::unique_lock<std::mutex> l(b.mutex);assert(b.cv.wait_for(l,1s,[]{return b.entered;}));}
 auto clearClose=std::async(std::launch::async,[&]{return d.Close();});
 bool protectedClear=clearClose.wait_for(100ms)==std::future_status::timeout;
 {std::lock_guard<std::mutex> l(b.mutex);b.release=true;b.cv.notify_all();}
 clear.get();assert(clearClose.get());
 assert(protectedClear && !b.freedDuringRead && b.nullCalls==0);
 std::cout<<"PASS actual owned USB: parallel input writes, read/close lifetime, late IO fence, idempotent close, reopen, exact partial timeout framing, ZLP, denied open/claim and concurrent clear/close\n";
}
