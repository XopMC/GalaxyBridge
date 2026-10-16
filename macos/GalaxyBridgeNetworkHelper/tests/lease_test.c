#include "GBNetworkLease.h"
#include <assert.h>
#include <string.h>
typedef struct {int apply, restore, save, conflict;} Fake;
static int save(void *p,const GBLease *l){(void)l;((Fake*)p)->save++;return 0;}
static int apply(void *p,GBLease *l){((Fake*)p)->apply++;l->tun_fd=42;return 0;}
static int restore(void *p,GBLease *l){(void)l;((Fake*)p)->restore++;return ((Fake*)p)->conflict?-1:0;}
int main(void){Fake f={0};GBLeaseOps ops={save,apply,restore};GBLease l={0};GBNetworkRequest r={0};
 r.version=1;r.operation=GB_NETWORK_CREATE;r.mtu=1400;r.trial_seconds=30;r.gateway_count=1;r.gateways[0].family=4;r.gateways[0].address[0]=192;r.gateways[0].address[1]=168;r.gateways[0].address[2]=42;r.gateways[0].address[3]=1;
 uint8_t token[16]={1};assert(gb_lease_create(&l,&r,501,token,100,&ops,&f)==0);assert(f.save>=1&&f.apply==1);assert(l.deadline==130);
 assert(gb_lease_heartbeat(&l,502,token,110,&ops,&f)!=0);uint8_t wrong[16]={2};assert(gb_lease_heartbeat(&l,501,wrong,110,&ops,&f)!=0);
 assert(gb_lease_heartbeat(&l,501,token,110,&ops,&f)==0);assert(l.deadline==130); /* hard trial deadline never extends */
 assert(gb_lease_expire(&l,126,&ops,&f)==0&&f.restore==1&&!l.active); /* heartbeat TTL 15s */
 memset(&l,0,sizeof(l));r.gateway_count=3;assert(gb_lease_create(&l,&r,501,token,100,&ops,&f)!=0);r.gateway_count=1;
 assert(gb_lease_create(&l,&r,501,token,100,&ops,&f)==0);f.conflict=1;assert(gb_lease_release(&l,501,token,&ops,&f)!=0&&l.active);f.conflict=0;assert(gb_lease_release(&l,501,token,&ops,&f)==0&&!l.active);
 memset(&l,0,sizeof(l));r.trial_seconds=0;r.gateway_count=0;assert(gb_lease_create(&l,&r,501,token,100,&ops,&f)==0);assert(l.deadline==UINT64_MAX);for(unsigned t=110;t<300;t+=10)assert(gb_lease_heartbeat(&l,501,token,t,&ops,&f)==0);assert(gb_lease_expire(&l,306,&ops,&f)==0&&!l.active);assert(gb_lease_release(&l,501,token,&ops,&f)==0);
 uint8_t pin[20]={1};uint8_t other[20]={2};assert(gb_pin_matches(pin,pin));assert(!gb_pin_matches(pin,other));return 0;}
