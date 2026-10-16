#include "galaxybridge_internet.h"
#include "hev-main.h"
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <sys/socket.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <arpa/inet.h>
enum { IDLE, PREPARED, RUNNING };
static pthread_mutex_t lifecycle=PTHREAD_MUTEX_INITIALIZER;
static int phase,cancel_requested,upstream_ready,stop_sent;
int gb_internet_tunnel_prepare(void){pthread_mutex_lock(&lifecycle);int result=phase==IDLE?0:EBUSY;if(!result){phase=PREPARED;cancel_requested=upstream_ready=stop_sent=0;}pthread_mutex_unlock(&lifecycle);return result;}
int gb_internet_tunnel_before_run(void){pthread_mutex_lock(&lifecycle);int run=phase==RUNNING&&!cancel_requested;upstream_ready=run;pthread_mutex_unlock(&lifecycle);return run;}
void gb_internet_tunnel_after_run(void){pthread_mutex_lock(&lifecycle);upstream_ready=0;pthread_mutex_unlock(&lifecycle);}
static int finish(int result){pthread_mutex_lock(&lifecycle);int cancelled=cancel_requested;phase=IDLE;cancel_requested=upstream_ready=stop_sent=0;pthread_mutex_unlock(&lifecycle);return cancelled?ECANCELED:result;}
static int hex64(const char*s){if(!s||strlen(s)!=64)return 0;for(int i=0;i<64;i++)if(!((s[i]>='0'&&s[i]<='9')||(s[i]>='a'&&s[i]<='f')))return 0;return 1;}
int gb_internet_tunnel_run(int fd,uint16_t port,const char*u,const char*p){
 pthread_mutex_lock(&lifecycle);
 if(phase==RUNNING){pthread_mutex_unlock(&lifecycle);return EBUSY;}
 if(phase==IDLE){cancel_requested=upstream_ready=stop_sent=0;}
 phase=RUNNING;int cancelled=cancel_requested;pthread_mutex_unlock(&lifecycle);
 if(cancelled)return finish(ECANCELED);
 if(fd<0||!port||!hex64(u)||!hex64(p))return finish(EINVAL);
#if defined(__APPLE__) && !defined(GB_TUNNEL_ADAPTER_TEST)
 char name[32]={0};socklen_t n=sizeof(name);if(getsockopt(fd,2,2,name,&n)||strncmp(name,"utun",4))return finish(EINVAL);
#endif
 char ipv6[INET6_ADDRSTRLEN]={0};
#if defined(__APPLE__) && !defined(GB_TUNNEL_ADAPTER_TEST)
 struct ifaddrs*all=NULL;if(!getifaddrs(&all)){for(struct ifaddrs*a=all;a;a=a->ifa_next)if(a->ifa_addr&&a->ifa_addr->sa_family==AF_INET6&&!strcmp(a->ifa_name,name)){struct in6_addr*v=&((struct sockaddr_in6*)a->ifa_addr)->sin6_addr;if(v->s6_addr[0]==0xfd)inet_ntop(AF_INET6,v,ipv6,sizeof(ipv6));}freeifaddrs(all);}
#endif
 char v6line[96]={0};if(ipv6[0])snprintf(v6line,sizeof(v6line),"  ipv6: '%s'\n",ipv6);
 char config[1024];int length=snprintf(config,sizeof(config),"tunnel:\n  mtu: 1400\n  ipv4: 198.18.0.1\n%ssocks5:\n  address: 127.0.0.1\n  port: %u\n  udp: tcp\n  username: '%s'\n  password: '%s'\nmisc:\n  log-level: error\n",v6line,port,u,p);
 int result=hev_socks5_tunnel_main_from_str((const unsigned char*)config,(unsigned)length,fd);memset(config,0,sizeof(config));return finish(result?EIO:0);}
void gb_internet_tunnel_stop(void){
 pthread_mutex_lock(&lifecycle);
 if(phase!=IDLE){cancel_requested=1;if(upstream_ready&&!stop_sent){stop_sent=1;hev_socks5_tunnel_quit();}}
 pthread_mutex_unlock(&lifecycle);
}
