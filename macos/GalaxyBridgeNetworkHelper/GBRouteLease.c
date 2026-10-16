#include "GBRouteLease.h"
#include <errno.h>
#include <string.h>
int gb_route_interface_is_vpn(const char*name){return name&&(!strncmp(name,"utun",4)||!strncmp(name,"tun",3)||!strncmp(name,"ppp",3));}
int gb_route_apply_one(GBRouteLeaseBits*b,uint32_t bit,int family,int half,uint32_t index,const GBRouteLeaseOps*o,void*c){int state=0;int result=o->inspect(c,family,half,index,&state);if(result)return result;if(state)return EBUSY;b->prepared|=bit;if(o->save(c,b))return EIO;result=o->add(c,family,half,index);if(result==EEXIST){b->prepared&=~bit;if(o->save(c,b))return EIO;return EBUSY;}if(result)return result;b->committed|=bit;b->prepared&=~bit;return o->save(c,b)?EIO:0;}
int gb_route_restore_one(GBRouteLeaseBits*b,uint32_t bit,int family,int half,uint32_t index,const GBRouteLeaseOps*o,void*c){if(!((b->committed|b->prepared)&bit))return 0;int state=0;int result=o->inspect(c,family,half,index,&state);if(result)return result;if(state==2)return EBUSY;if(state==1){result=o->remove(c,family,half,index);if(result)return result;}b->committed&=~bit;b->prepared&=~bit;return o->save(c,b)?EIO:0;}
