#include "GBProgramFingerprint.h"
#include <CommonCrypto/CommonDigest.h>
#include <mach-o/loader.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
int gb_program_fingerprint(const void*input,size_t length,uint8_t hash[32]){
 if(!input||length<sizeof(struct mach_header_64)||length>512u*1024u*1024u)return EINVAL;
 const struct mach_header_64*head=input;if(head->magic!=MH_MAGIC_64||head->ncmds>4096||head->sizeofcmds>length-sizeof(*head))return ENOTSUP;
 unsigned char*bytes=malloc(length);if(!bytes)return ENOMEM;memcpy(bytes,input,length);
 size_t cursor=sizeof(*head),signature=0,end=0;struct segment_command_64*linkedit=NULL;
 for(unsigned i=0;i<head->ncmds;i++){if(cursor+sizeof(struct load_command)>sizeof(*head)+head->sizeofcmds){free(bytes);return EINVAL;}struct load_command*c=(void*)(bytes+cursor);if(c->cmdsize<sizeof(*c)||c->cmdsize>sizeof(*head)+head->sizeofcmds-cursor){free(bytes);return EINVAL;}
 if(c->cmd==LC_CODE_SIGNATURE){if(signature||c->cmdsize!=sizeof(struct linkedit_data_command)){free(bytes);return EINVAL;}struct linkedit_data_command*code=(void*)c;signature=code->dataoff;end=signature+code->datasize;if(signature<sizeof(*head)+head->sizeofcmds||end<signature||end!=length){free(bytes);return EINVAL;}code->dataoff=code->datasize=0;}
 if(c->cmd==LC_SEGMENT_64&&c->cmdsize>=sizeof(struct segment_command_64)){struct segment_command_64*segment=(void*)c;if(!strncmp(segment->segname,"__LINKEDIT",16))linkedit=segment;}
 cursor+=c->cmdsize;}
 if(cursor!=sizeof(*head)+head->sizeofcmds||!signature||!linkedit||linkedit->fileoff>signature){free(bytes);return EINVAL;}
 /* Codesign can resize the signature and its enclosing __LINKEDIT mapping. */
 linkedit->filesize=signature-linkedit->fileoff;linkedit->vmsize=0;
 CC_SHA256_CTX state;CC_SHA256_Init(&state);static const char domain[]="GalaxyBridgeProgramFingerprint-v1";CC_SHA256_Update(&state,domain,sizeof(domain));CC_SHA256_Update(&state,bytes,(CC_LONG)signature);CC_SHA256_Final(hash,&state);free(bytes);return 0;}
int gb_program_fingerprint_file(const char*path,uint8_t hash[32]){int f=open(path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(f<0)return errno;struct stat before,after;if(fstat(f,&before)||!S_ISREG(before.st_mode)||before.st_size<=0||before.st_size>512*1024*1024){close(f);return EINVAL;}size_t n=(size_t)before.st_size;unsigned char*b=malloc(n);if(!b){close(f);return ENOMEM;}size_t read_count=0;while(read_count<n){ssize_t count=read(f,b+read_count,n-read_count);if(count<=0){free(b);close(f);return EIO;}read_count+=(size_t)count;}int stable=fstat(f,&after)==0&&before.st_dev==after.st_dev&&before.st_ino==after.st_ino&&before.st_size==after.st_size&&before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec&&before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec&&before.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec&&before.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec;close(f);int result=stable?gb_program_fingerprint(b,n,hash):ESTALE;free(b);return result;}
