#include "GBNetworkLease.h"
#include <errno.h>
#include <pthread.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* Inert helper/worker boundaries: no sockets, utun, routes or DNS settings. */
static pthread_mutex_t fixture_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t fixture_wake = PTHREAD_COND_INITIALIZER;
static int fixture_stopped, fixture_active, fixture_rejection, fixture_updates, fixture_last_gateway;
void gb_fixture_reject_admission(int mode) {
    pthread_mutex_lock(&fixture_lock);
    fixture_rejection = mode; fixture_updates = 0;
    pthread_mutex_unlock(&fixture_lock);
}
int gb_fixture_update_count(void) {
    pthread_mutex_lock(&fixture_lock); int count = fixture_updates;
    pthread_mutex_unlock(&fixture_lock); return count;
}
int gb_fixture_last_gateway(void) {
    pthread_mutex_lock(&fixture_lock); int address = fixture_last_gateway;
    pthread_mutex_unlock(&fixture_lock); return address;
}
int gb_network_helper_request(const GBNetworkRequest *request, GBNetworkReply *reply, int *fd) {
    pthread_mutex_lock(&fixture_lock);
    memset(reply, 0, sizeof(*reply)); reply->version = 1; *fd = -1;
    int status = 0;
    if (request->operation == GB_NETWORK_CREATE) {
        fixture_active = 1; reply->token[0] = 1; *fd = dup(STDIN_FILENO);
    } else if (request->operation == GB_NETWORK_RELEASE) {
        fixture_active = 0; pthread_cond_broadcast(&fixture_wake);
    } else if (request->operation == GB_NETWORK_UPDATE_GATEWAYS) {
        fixture_updates++;
        fixture_last_gateway = request->gateway_count ? request->gateways[0].address[3] : 0;
        if (request->gateway_count == 2 && fixture_rejection) {
            if (fixture_rejection == 2) fixture_active = 0;
            if (fixture_rejection == 4) {
                fixture_stopped = 1; pthread_cond_broadcast(&fixture_wake);
                struct timespec deadline; clock_gettime(CLOCK_REALTIME, &deadline); deadline.tv_sec += 2;
                while (fixture_active && pthread_cond_timedwait(&fixture_wake, &fixture_lock, &deadline) != ETIMEDOUT) {}
                pthread_mutex_unlock(&fixture_lock);
                reply->status = EINVAL; return EINVAL;
            }
            status = EINVAL;
        } else if (!fixture_active || fixture_rejection == 3) status = EPERM;
    } else if (!fixture_active) status = EPERM;
    reply->status = status;
    pthread_mutex_unlock(&fixture_lock); return status;
}
int gb_internet_tunnel_prepare(void) {
    pthread_mutex_lock(&fixture_lock); fixture_stopped = 0;
    pthread_mutex_unlock(&fixture_lock); return 0;
}
int gb_internet_tunnel_run(int fd, uint16_t port, const char *user, const char *pass) {
    (void)fd; (void)port; (void)user; (void)pass;
    pthread_mutex_lock(&fixture_lock);
    while (!fixture_stopped) pthread_cond_wait(&fixture_wake, &fixture_lock);
    pthread_mutex_unlock(&fixture_lock); return 0;
}
void gb_internet_tunnel_stop(void) {
    pthread_mutex_lock(&fixture_lock); fixture_stopped = 1;
    pthread_cond_broadcast(&fixture_wake); pthread_mutex_unlock(&fixture_lock);
}
