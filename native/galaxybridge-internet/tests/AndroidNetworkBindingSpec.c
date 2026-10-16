#include <assert.h>
#include <errno.h>
#include <netdb.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stddef.h>
typedef uint64_t net_handle_t;
#define ANDROID_LOG_WARN 5
static atomic_uint_fast64_t network;
static atomic_uint failure_count;
static unsigned bind_calls, resolver_calls, logs;
static uint64_t bound_network, resolved_network;
static int bound_fd, bind_error;
static int android_setsocknetwork(net_handle_t value,int fd){bind_calls++;bound_network=value;bound_fd=fd;if(bind_error){errno=bind_error;return -1;}return 0;}
static int android_getaddrinfofornetwork(net_handle_t value,const char*n,const char*s,const struct addrinfo*h,struct addrinfo**r){(void)n;(void)s;(void)h;(void)r;resolver_calls++;resolved_network=value;return EAI_NONAME;}
static int __android_log_print(int priority,const char*tag,const char*format,...){(void)priority;(void)tag;(void)format;logs++;errno=EIO;return 0;}
#include "AndroidNetworkBindingUnderTest.h"
int main(void){
 struct addrinfo*answer=NULL;
 assert(gb_android_bind_socket(47)==-1&&errno==ENETUNREACH&&bind_calls==0);
 assert(__wrap_getaddrinfo("fixture.invalid",NULL,NULL,&answer)==EAI_SYSTEM&&errno==ENETUNREACH&&resolver_calls==0);
 uint64_t selected=UINT64_C(0x12345678cafed00d);atomic_store(&network,selected);
 assert(gb_android_bind_socket(47)==0&&bind_calls==1&&bound_network==selected&&bound_fd==47);
 assert(__wrap_getaddrinfo("fixture.invalid",NULL,NULL,&answer)==EAI_NONAME&&resolver_calls==1&&resolved_network==selected);
 bind_error=EACCES;assert(gb_android_bind_socket(48)==-1&&errno==EACCES);
 atomic_store(&failure_count,0);logs=0;
 for(int i=0;i<25;i++)assert(gb_android_bind_socket(49)==-1&&errno==EACCES);
 assert(logs==16);return 0;
}
