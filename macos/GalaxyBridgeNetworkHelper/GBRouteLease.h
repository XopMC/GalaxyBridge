#ifndef GB_ROUTE_LEASE_H
#define GB_ROUTE_LEASE_H
#include <stdint.h>
typedef struct {uint32_t committed,prepared;} GBRouteLeaseBits;
/* inspect: 0 absent, 1 exact owned route+live interface marker, 2 foreign/conflicted. */
typedef struct {int(*inspect)(void*,int,int,uint32_t,int*);int(*add)(void*,int,int,uint32_t);int(*remove)(void*,int,int,uint32_t);int(*save)(void*,const GBRouteLeaseBits*);} GBRouteLeaseOps;
int gb_route_apply_one(GBRouteLeaseBits*,uint32_t,int,int,uint32_t,const GBRouteLeaseOps*,void*);
int gb_route_restore_one(GBRouteLeaseBits*,uint32_t,int,int,uint32_t,const GBRouteLeaseOps*,void*);
int gb_route_interface_is_vpn(const char*);
#endif
