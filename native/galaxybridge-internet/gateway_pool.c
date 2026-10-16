#include "galaxybridge_internet.h"
#include <pthread.h>
#include <string.h>
#include <errno.h>
#define FLOWS 4096
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static struct {uint64_t id;int gateway,active;uint16_t port;} flows[FLOWS];
static struct {int healthy;unsigned cost,active;} gateways[2];
static uint16_t ports[2];
static uint64_t total_started[2];
static int policy=1,fixed_gateway;
void gb_gateway_pool_reset(void){pthread_mutex_lock(&lock);memset(flows,0,sizeof(flows));memset(gateways,0,sizeof(gateways));memset(ports,0,sizeof(ports));memset(total_started,0,sizeof(total_started));policy=1;fixed_gateway=0;pthread_mutex_unlock(&lock);}
void gb_gateway_pool_update(unsigned g,int h,unsigned c){if(g>1)return;pthread_mutex_lock(&lock);gateways[g].healthy=!!h;gateways[g].cost=c;pthread_mutex_unlock(&lock);}
static int acquire_locked(uint64_t id,int fixed,int balance){
 int empty=-1;
 for(int i=0;i<FLOWS;i++){if(flows[i].active&&flows[i].id==id)return i;if(!flows[i].active&&empty<0)empty=i;}
 int best=-1;
 if(fixed>=0&&fixed<=1){if(gateways[fixed].healthy)best=fixed;}
 else if(fixed==-1)for(int g=0;g<2;g++)if(gateways[g].healthy&&(best<0||(balance?gateways[g].active:gateways[g].cost)<(balance?gateways[best].active:gateways[best].cost)))best=g;
 if(best<0||empty<0)return -1;
 flows[empty].id=id;flows[empty].gateway=best;flows[empty].port=ports[best];flows[empty].active=1;gateways[best].active++;total_started[best]++;
 return empty;
}
int gb_gateway_flow_acquire(uint64_t id,int fixed,int balance){pthread_mutex_lock(&lock);int index=acquire_locked(id,fixed,balance);int result=index<0?-1:flows[index].gateway;pthread_mutex_unlock(&lock);return result;}
void gb_gateway_flow_release(uint64_t id){pthread_mutex_lock(&lock);for(int i=0;i<FLOWS;i++)if(flows[i].active&&flows[i].id==id){gateways[flows[i].gateway].active--;flows[i].active=0;break;}pthread_mutex_unlock(&lock);}
int gb_internet_tunnel_set_gateways_checked(uint16_t p0,uint16_t p1,uint32_t mask,int mode,int fixed,uint32_t rebind_mask){
 if(!p0||mask>3||rebind_mask>3||mode<0||mode>2||fixed<0||fixed>1||((mask&2)&&!p1))return EINVAL;
 pthread_mutex_lock(&lock);
 for(int g=0;g<2;g++)if((rebind_mask&(1u<<g))&&gateways[g].active){pthread_mutex_unlock(&lock);return EBUSY;}
 ports[0]=p0;ports[1]=p1;policy=mode;fixed_gateway=fixed;
 for(int g=0;g<2;g++)gateways[g].healthy=!!(mask&(1u<<g));
 pthread_mutex_unlock(&lock);return 0;
}
int gb_internet_tunnel_set_gateways(uint16_t p0,uint16_t p1,uint32_t mask,int mode,int fixed){return gb_internet_tunnel_set_gateways_checked(p0,p1,mask,mode,fixed,0);}
uint16_t gb_gateway_flow_port(uint64_t id,uint16_t fallback){
 pthread_mutex_lock(&lock);
 if(!ports[0]){ports[0]=fallback;gateways[0].healthy=1;}
 int index=acquire_locked(id,policy==0?fixed_gateway:-1,policy==2);
 uint16_t result=index<0?0:flows[index].port;
 pthread_mutex_unlock(&lock);return result;
}
void gb_gateway_pool_stats(uint32_t active[2]){if(!active)return;pthread_mutex_lock(&lock);active[0]=gateways[0].active;active[1]=gateways[1].active;pthread_mutex_unlock(&lock);}

void gb_gateway_pool_total_started(uint64_t started[2]){if(!started)return;pthread_mutex_lock(&lock);started[0]=total_started[0];started[1]=total_started[1];pthread_mutex_unlock(&lock);}
