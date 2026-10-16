#ifndef GB_NETWORK_LEASE_H
#define GB_NETWORK_LEASE_H
#include <stdint.h>
#include <sys/types.h>
#define GB_NETWORK_VERSION 1
#define GB_NETWORK_CREATE 1
#define GB_NETWORK_HEARTBEAT 2
#define GB_NETWORK_RELEASE 3
#define GB_NETWORK_STATUS 4
#define GB_NETWORK_UPDATE_GATEWAYS 5
#define GB_NETWORK_UNINSTALL 6
#define GB_NETWORK_IPV6 1u
#define GB_NETWORK_DNS 2u
#define GB_NETWORK_DEFAULT_ROUTES 4u
#define GB_NETWORK_MUTATION_APPROVED 8u
#define GB_NETWORK_MAX_GATEWAYS 2
typedef struct {uint32_t family; uint8_t address[16];uint32_t interface_index;} GBGatewayAddress;
typedef struct {uint32_t version,operation,mtu,flags,trial_seconds,gateway_count,dns_port;uint8_t token[16];GBGatewayAddress gateways[2];} GBNetworkRequest;
typedef struct {int32_t status;uint32_t version;uint8_t token[16];char interface_name[16];uint64_t deadline;} GBNetworkReply;
typedef struct {int active,tun_fd;uid_t owner;uint8_t token[16];char interface_name[16];uint32_t interface_index,route_mask,route_prepared_mask,dns_set;uint64_t started,heartbeat,deadline;GBNetworkRequest request;} GBLease;
typedef struct {int(*save)(void*,const GBLease*);int(*apply)(void*,GBLease*);int(*restore)(void*,GBLease*);} GBLeaseOps;
int gb_pin_matches(const uint8_t a[20],const uint8_t b[20]);
int gb_request_valid(const GBNetworkRequest*);
int gb_lease_create(GBLease*,const GBNetworkRequest*,uid_t,const uint8_t[16],uint64_t,const GBLeaseOps*,void*);
int gb_lease_heartbeat(GBLease*,uid_t,const uint8_t[16],uint64_t,const GBLeaseOps*,void*);
int gb_lease_release(GBLease*,uid_t,const uint8_t[16],const GBLeaseOps*,void*);
int gb_lease_expire(GBLease*,uint64_t,const GBLeaseOps*,void*);
/* Unprivileged AF_UNIX client. create returns received utun fd, other operations return -1 fd. */
int gb_network_helper_request(const GBNetworkRequest*,GBNetworkReply*,int*);
#endif
