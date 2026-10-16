#ifndef GALAXYBRIDGE_INTERNET_H
#define GALAXYBRIDGE_INTERNET_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Blocking, unprivileged; caller runs on a dedicated worker and owns the passed utun FD.
 * The local SOCKS endpoint MUST be the authenticated paired-TLS gateway adapter.
 * No arbitrary YAML/script/logfile path enters the embedded tunnel. */
/* Reserve synchronously before scheduling run(). STOP is latched for that
 * reservation until run() retires it. EBUSY never replaces a live owner. */
int gb_internet_tunnel_prepare(void);
/* Embedded upstream lifecycle hooks: after init and before cleanup, respectively. */
int gb_internet_tunnel_before_run(void);
void gb_internet_tunnel_after_run(void);
int gb_internet_tunnel_run(int tun_fd,uint16_t loopback_port,const char *username_hex64,const char *password_hex64);
void gb_internet_tunnel_stop(void);
/* mode 0=fixed, 1=automatic cost, 2=balanced active new flows; fixedGateway 0/1. */
int gb_internet_tunnel_set_gateways(uint16_t port0,uint16_t port1,uint32_t healthy_mask,int mode,int fixed_gateway);
int gb_internet_tunnel_set_gateways_checked(uint16_t port0,uint16_t port1,uint32_t healthy_mask,int mode,int fixed_gateway,uint32_t rebind_mask);
void gb_gateway_pool_stats(uint32_t active[2]);
void gb_gateway_pool_total_started(uint64_t started[2]);
/* Embedded upstream hook, not a packet-processing privilege boundary. */
uint16_t gb_gateway_flow_port(uint64_t flow_id,uint16_t fallback_port);
/* Per-new-flow gateway choice. Existing flow IDs stay pinned, even if gateway health changes.
 * Returns 0/1; -1 if unavailable/full. release only after that flow's sockets have closed. */
void gb_gateway_pool_reset(void);
void gb_gateway_pool_update(unsigned gateway,int healthy,unsigned cost);
int gb_gateway_flow_acquire(uint64_t flow_id,int fixed_gateway,int balance);
void gb_gateway_flow_release(uint64_t flow_id);
#ifdef __cplusplus
}
#endif
#endif
