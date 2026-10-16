#include "GBNetworkLease.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
int gb_network_helper_request(const GBNetworkRequest*r,GBNetworkReply*out,int*fd){if(!r||!out||!fd)return EINVAL;*fd=-1;int s=socket(AF_UNIX,SOCK_SEQPACKET,0);if(s<0)return errno;int no_sigpipe=1;setsockopt(s,SOL_SOCKET,SO_NOSIGPIPE,&no_sigpipe,sizeof(no_sigpipe));struct sockaddr_un a={.sun_family=AF_UNIX};strcpy(a.sun_path,"/var/run/GalaxyBridgeNetworkHelper.sock");struct timeval timeout={3,0};setsockopt(s,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));setsockopt(s,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));if(connect(s,(struct sockaddr*)&a,sizeof(a))||send(s,r,sizeof(*r),0)!=(ssize_t)sizeof(*r)){int e=errno;close(s);return e?e:EIO;}char control[CMSG_SPACE(sizeof(int))]={0};struct iovec iov={out,sizeof(*out)};struct msghdr m={.msg_iov=&iov,.msg_iovlen=1,.msg_control=control,.msg_controllen=sizeof(control)};ssize_t n=recvmsg(s,&m,0);close(s);if(n!=(ssize_t)sizeof(*out)||(m.msg_flags&(MSG_TRUNC|MSG_CTRUNC)))return EPROTO;for(struct cmsghdr*c=CMSG_FIRSTHDR(&m);c;c=CMSG_NXTHDR(&m,c))if(c->cmsg_level==SOL_SOCKET&&c->cmsg_type==SCM_RIGHTS&&c->cmsg_len==CMSG_LEN(sizeof(int)))memcpy(fd,CMSG_DATA(c),sizeof(int));if(*fd>=0)fcntl(*fd,F_SETFD,FD_CLOEXEC);if(out->version!=1||(out->status==0&&r->operation==GB_NETWORK_CREATE&&*fd<0)){if(*fd>=0)close(*fd);*fd=-1;return EPROTO;}if(out->status||r->operation!=GB_NETWORK_CREATE){if(*fd>=0)close(*fd);*fd=-1;}return out->status;}
