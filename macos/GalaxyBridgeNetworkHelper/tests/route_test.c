#include "GBRouteLease.h"
#include <assert.h>
#include <errno.h>
typedef struct{int state,add_error,adds,deletes,saves;}Fake;
static int inspect(void*c,int f,int h,uint32_t i,int*s){(void)f;(void)h;(void)i;*s=((Fake*)c)->state;return 0;}
static int add(void*c,int f,int h,uint32_t i){(void)f;(void)h;(void)i;Fake*x=c;x->adds++;x->state=x->add_error==EEXIST?2:1;return x->add_error;}
static int remove_route(void*c,int f,int h,uint32_t i){(void)f;(void)h;(void)i;Fake*x=c;assert(x->state==1);x->deletes++;x->state=0;return 0;}
static int save(void*c,const GBRouteLeaseBits*b){(void)b;((Fake*)c)->saves++;return 0;}
int main(void){GBRouteLeaseOps ops={inspect,add,remove_route,save};GBRouteLeaseBits bits={0};Fake f={.state=2};assert(gb_route_apply_one(&bits,1,4,0,7,&ops,&f)==EBUSY);assert(!f.adds&&!f.deletes&&!bits.prepared&&!bits.committed);
 f=(Fake){.add_error=EEXIST};assert(gb_route_apply_one(&bits,1,4,0,7,&ops,&f)==EBUSY);assert(!bits.prepared&&!bits.committed);assert(gb_route_restore_one(&bits,1,4,0,7,&ops,&f)==0&&!f.deletes); /* foreign route from EEXIST is never owned */
 f=(Fake){.add_error=EIO};assert(gb_route_apply_one(&bits,1,4,0,7,&ops,&f)==EIO&&bits.prepared==1&&bits.committed==0);assert(gb_route_restore_one(&bits,1,4,0,7,&ops,&f)==0&&f.deletes==1); /* uncertain write: require exact current ownership proof */
 f=(Fake){0};assert(gb_route_apply_one(&bits,1,4,0,7,&ops,&f)==0&&bits.committed==1&&!bits.prepared);f.state=2;assert(gb_route_restore_one(&bits,1,4,0,7,&ops,&f)==EBUSY&&!f.deletes&&bits.committed==1);
 assert(gb_route_interface_is_vpn("utun4")&&gb_route_interface_is_vpn("tun0")&&gb_route_interface_is_vpn("ppp0"));assert(!gb_route_interface_is_vpn("en0")&&!gb_route_interface_is_vpn("bridge0"));return 0;}
