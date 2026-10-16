#include "galaxybridge_internet.h"
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <time.h>
#include <string.h>
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed=PTHREAD_COND_INITIALIZER;
static int entered,permit_ready,ready,permit_loop,loop_entered,quit,after,permit_return,calls,quit_calls;
static const char credentials[]="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
static void wait_for(int*flag){struct timespec until;clock_gettime(CLOCK_REALTIME,&until);until.tv_sec+=2;while(!*flag)assert(pthread_cond_timedwait(&changed,&lock,&until)==0);}
static void set(int*flag){pthread_mutex_lock(&lock);*flag=1;pthread_cond_broadcast(&changed);pthread_mutex_unlock(&lock);}
static void await(int*flag){pthread_mutex_lock(&lock);wait_for(flag);pthread_mutex_unlock(&lock);}
static void reset(int block_ready,int block_loop,int block_return){pthread_mutex_lock(&lock);entered=ready=loop_entered=quit=after=calls=quit_calls=0;permit_ready=!block_ready;permit_loop=!block_loop;permit_return=!block_return;pthread_mutex_unlock(&lock);}
int hev_socks5_tunnel_main_from_str(const unsigned char*config,unsigned length,int fd){(void)config;(void)length;(void)fd;pthread_mutex_lock(&lock);calls++;entered=1;pthread_cond_broadcast(&changed);wait_for(&permit_ready);pthread_mutex_unlock(&lock);
 int run=gb_internet_tunnel_before_run();
 pthread_mutex_lock(&lock);ready=1;pthread_cond_broadcast(&changed);wait_for(&permit_loop);if(run){loop_entered=1;pthread_cond_broadcast(&changed);wait_for(&quit);}pthread_mutex_unlock(&lock);
 gb_internet_tunnel_after_run();set(&after);await(&permit_return);return 0;}
void hev_socks5_tunnel_quit(void){pthread_mutex_lock(&lock);quit_calls++;quit=1;pthread_cond_broadcast(&changed);pthread_mutex_unlock(&lock);}
static void*worker(void*result){*(int*)result=gb_internet_tunnel_run(7,1080,credentials,credentials);return NULL;}
static pthread_t start(int*result){pthread_t thread;assert(gb_internet_tunnel_prepare()==0);assert(pthread_create(&thread,NULL,worker,result)==0);return thread;}
int main(void){int result;pthread_t thread;
 /* Reproduces the exact detached-worker scheduling window, without creating TUN. */
 reset(0,0,0);assert(gb_internet_tunnel_prepare()==0);gb_internet_tunnel_stop();result=gb_internet_tunnel_run(7,1080,credentials,credentials);assert(result==ECANCELED&&calls==0);
 /* STOP during upstream initialization is latched until the run-loop boundary. */
 reset(1,0,0);thread=start(&result);await(&entered);gb_internet_tunnel_stop();set(&permit_ready);pthread_join(thread,NULL);assert(result==ECANCELED&&!loop_entered&&!quit_calls);
 /* STOP after ready but before the loop starts is delivered exactly once. */
 reset(0,1,0);thread=start(&result);await(&ready);gb_internet_tunnel_stop();set(&permit_loop);pthread_join(thread,NULL);assert(result==ECANCELED&&quit_calls==1);
 /* Repeated normal start/STOP and idle STOP never poison the next generation. */
 for(int i=0;i<30;i++){reset(0,0,0);gb_internet_tunnel_stop();thread=start(&result);await(&loop_entered);gb_internet_tunnel_stop();pthread_join(thread,NULL);assert(result==ECANCELED&&quit_calls==1);}
 /* Overlapping native owners are refused, and natural completion is reusable. */
 reset(0,0,0);thread=start(&result);await(&loop_entered);assert(gb_internet_tunnel_prepare()==EBUSY);assert(gb_internet_tunnel_run(7,1080,credentials,credentials)==EBUSY);set(&quit);pthread_join(thread,NULL);assert(result==0&&quit_calls==0);
 /* A late STOP after upstream exited must not call upstream quit on idle state. */
 reset(0,0,1);thread=start(&result);await(&loop_entered);set(&quit);await(&after);gb_internet_tunnel_stop();assert(quit_calls==0);set(&permit_return);pthread_join(thread,NULL);assert(result==ECANCELED);
 reset(0,0,0);assert(gb_internet_tunnel_prepare()==0);assert(gb_internet_tunnel_prepare()==EBUSY);assert(gb_internet_tunnel_run(-1,1080,credentials,credentials)==EINVAL);assert(gb_internet_tunnel_prepare()==0);gb_internet_tunnel_stop();assert(gb_internet_tunnel_run(7,1080,credentials,credentials)==ECANCELED);
 puts("Tunnel lifecycle PASS: early STOP, initializing/ready/exiting windows, repeated reuse, invalid-start reservation cleanup; no TUN/network operations.");return 0;}
