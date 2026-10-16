#include <jni.h>
#include <android/multinetwork.h>
#include <android/log.h>
#include <netdb.h>
#include <pthread.h>
#include <stdatomic.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <time.h>
#include "hev-main.h"
static pthread_mutex_t mutex=PTHREAD_MUTEX_INITIALIZER;
static atomic_uint_fast64_t network;
static atomic_int finished;
static atomic_int listening_ready;
static atomic_uint failure_count;
static int stopping;
static pthread_t worker;
static int joined=1,port;
static uint64_t handle,sequence;
static char config[1024];
/* Stage numbers: 1 socket, 2 selected-network bind, 3 bind-policy, 4 connect.
 * Bounded failure-only diagnostics contain no remote address, identity or data. */
void gb_android_upstream_failure(int stage,int error){int saved=errno;if(atomic_fetch_add(&failure_count,1)<16)__android_log_print(ANDROID_LOG_WARN,"GBInternetNative","upstream_failure stage=%d errno=%d",stage,error);errno=saved;}
int gb_android_bind_socket(int fd){uint64_t n=atomic_load(&network);if(!n){errno=ENETUNREACH;gb_android_upstream_failure(2,errno);return -1;}int result=android_setsocknetwork((net_handle_t)n,fd);if(result<0)gb_android_upstream_failure(2,errno);return result;}
int __wrap_getaddrinfo(const char*node,const char*service,const struct addrinfo*hints,struct addrinfo**result){uint64_t n=atomic_load(&network);if(!n){errno=ENETUNREACH;return EAI_SYSTEM;}return android_getaddrinfofornetwork((net_handle_t)n,node,service,hints,result);}
void gb_android_listener_ready(int fd){struct sockaddr_storage address;socklen_t n=sizeof(address);if(getsockname(fd,(void*)&address,&n))return;int p=address.ss_family==AF_INET6?ntohs(((struct sockaddr_in6*)&address)->sin6_port):address.ss_family==AF_INET?ntohs(((struct sockaddr_in*)&address)->sin_port):0;if(p==port)atomic_store(&listening_ready,1);}
static void*run(void*unused){(void)unused;hev_socks5_server_main_from_str((unsigned char*)config,(unsigned)strlen(config));atomic_store(&listening_ready,0);atomic_store(&finished,1);return NULL;}
static int stop_locked(void){if(joined){handle=0;return 0;}stopping=1;atomic_store(&network,0);if(!atomic_load(&finished))hev_socks5_server_quit();for(int i=0;i<200&&!atomic_load(&finished);i++){struct timespec t={0,10000000};nanosleep(&t,NULL);}if(!atomic_load(&finished))return ETIMEDOUT;pthread_join(worker,NULL);joined=1;handle=0;port=0;memset(config,0,sizeof(config));return 0;}
static int parse(const char*input,unsigned*number,char user[65],char pass[65]){int consumed=0;if(sscanf(input,"port: %u\nusername: %64[0-9a-f]\npassword: %64[0-9a-f]\n%n",number,user,pass,&consumed)!=3||!consumed||input[consumed]||!*number||*number>65535||strlen(user)!=64||strlen(pass)!=64)return 0;return 1;}
JNIEXPORT jlong JNICALL Java_com_xopmc_galaxybridge_internet_NativeInternetGateway_start(JNIEnv*env,jclass klass,jstring yaml,jlong net){(void)klass;if(!yaml||net<=0)return 0;const char*text=(*env)->GetStringUTFChars(env,yaml,NULL);if(!text)return 0;unsigned number=0;char user[65]={0},pass[65]={0};int valid=parse(text,&number,user,pass);(*env)->ReleaseStringUTFChars(env,yaml,text);if(!valid)return 0;pthread_mutex_lock(&mutex);if(!joined&&atomic_load(&finished))stop_locked();if(!joined){pthread_mutex_unlock(&mutex);return 0;}
 snprintf(config,sizeof(config),"main:\n  workers: 1\n  listen-address: 127.0.0.1\n  port: %u\n  udp-listen-address: 127.0.0.1\nauth:\n  username: '%s'\n  password: '%s'\nmisc:\n  log-level: error\n",number,user,pass);memset(user,0,sizeof(user));memset(pass,0,sizeof(pass));stopping=0;atomic_store(&failure_count,0);atomic_store(&listening_ready,0);atomic_store(&network,(uint64_t)net);atomic_store(&finished,0);port=(int)number;if(pthread_create(&worker,NULL,run,NULL)){port=0;pthread_mutex_unlock(&mutex);return 0;}joined=0;handle=++sequence;
 int ready=0;for(int i=0;i<100&&!atomic_load(&finished);i++){ready=atomic_load(&listening_ready);if(ready)break;struct timespec t={0,20000000};nanosleep(&t,NULL);}if(!ready){stop_locked();pthread_mutex_unlock(&mutex);return 0;}jlong result=(jlong)handle;pthread_mutex_unlock(&mutex);return result;}
JNIEXPORT jint JNICALL Java_com_xopmc_galaxybridge_internet_NativeInternetGateway_stop(JNIEnv*env,jclass klass,jlong value){(void)env;(void)klass;pthread_mutex_lock(&mutex);int result=(uint64_t)value==handle?stop_locked():ENOENT;pthread_mutex_unlock(&mutex);return result;}
JNIEXPORT jint JNICALL Java_com_xopmc_galaxybridge_internet_NativeInternetGateway_updateNetwork(JNIEnv*env,jclass klass,jlong value,jlong net){(void)env;(void)klass;pthread_mutex_lock(&mutex);int result=ENOENT;if((uint64_t)value==handle&&!joined&&!stopping&&net>0){atomic_store(&network,(uint64_t)net);result=0;}else if((uint64_t)value==handle&&net==0){atomic_store(&network,0);result=ENETUNREACH;}pthread_mutex_unlock(&mutex);return result;}
JNIEXPORT jint JNICALL Java_com_xopmc_galaxybridge_internet_NativeInternetGateway_localPort(JNIEnv*env,jclass klass,jlong value){(void)env;(void)klass;pthread_mutex_lock(&mutex);int result=(uint64_t)value==handle&&!joined&&!stopping&&!atomic_load(&finished)?port:0;pthread_mutex_unlock(&mutex);return result;}
