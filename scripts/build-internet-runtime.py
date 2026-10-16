#!/usr/bin/env python3
"""Build immutable MIT Hev sources and the small Galaxy Bridge adapters. Never installs anything."""
import argparse, hashlib, json, os, pathlib, shutil, subprocess, tarfile, tempfile, urllib.request
ROOT = pathlib.Path(__file__).resolve().parents[1]
NATIVE = ROOT / 'native/galaxybridge-internet'
LOCK = json.loads((NATIVE / 'upstream.lock.json').read_text())
def run(argv, cwd=None, env=None):
    subprocess.run([str(x) for x in argv], cwd=cwd, env=env, check=True)
def sources(name, destination, cache):
    item=LOCK['components'][name]; archive=cache/'archives'/f"{name}-{item['commit']}.tar.gz"
    archive.parent.mkdir(parents=True,exist_ok=True)
    if not archive.exists():
        payload=urllib.request.urlopen(item['archive'],timeout=90).read()
        if hashlib.sha256(payload).hexdigest()!=item['sha256']: raise RuntimeError('source checksum mismatch: '+name)
        archive.write_bytes(payload)
    if hashlib.sha256(archive.read_bytes()).hexdigest()!=item['sha256']: raise RuntimeError('cached source checksum mismatch: '+name)
    destination.mkdir(parents=True,exist_ok=True)
    links=[]
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            parts=pathlib.PurePosixPath(member.name).parts[1:]
            if not parts: continue
            if '..' in parts or member.islnk() or not (member.isfile() or member.isdir() or member.issym()): raise RuntimeError('unsafe source archive')
            target=destination.joinpath(*parts)
            if member.issym():
                if not (target.parent/member.linkname).resolve().is_relative_to(destination.resolve()): raise RuntimeError('source link escapes checkout')
                links.append((target,member.linkname))
            elif member.isdir(): target.mkdir(parents=True,exist_ok=True)
            else:
                target.parent.mkdir(parents=True,exist_ok=True)
                target.write_bytes(tar.extractfile(member).read())
                target.chmod(member.mode & 0o777)
    for target,link in links:
        target.parent.mkdir(parents=True,exist_ok=True);target.symlink_to(link)
    if name in ('hev-socks5-server','hev-socks5-tunnel'):
        (destination/'.rev-id').write_text(item['commit'][:12]+'\n')
        for sub, dependency in LOCK['submodules'].items():
            if dependency=='lwip' and name.endswith('server'): continue
            sources(dependency,destination/sub,cache)
def replace(path, old, new):
    text=path.read_text()
    if text.count(old)!=1: raise RuntimeError('upstream patch anchor changed: '+str(path))
    path.write_text(text.replace(old,new))
def macos(cache, artifacts):
    work=cache/'build-macos'
    if work.exists(): shutil.rmtree(work)
    sources('hev-socks5-tunnel',work,cache)
    path=work/'src/hev-socks5-session.c'
    replace(path,'#include <string.h>','#include <string.h>\n#include <stdint.h>\nextern uint16_t gb_gateway_flow_port(uint64_t,uint16_t);\nextern void gb_gateway_flow_release(uint64_t);')
    replace(path,'void\nhev_socks5_session_run (HevSocks5Session *self)','static void\nhev_socks5_session_run_selected (HevSocks5Session *self, int selected_port)')
    replace(path,'                                     srv->port);','                                     selected_port);')
    replace(path,'void\nhev_socks5_session_terminate (HevSocks5Session *self)','void\nhev_socks5_session_run (HevSocks5Session *self)\n{\n    uint64_t id = (uint64_t)(uintptr_t)self;\n    uint16_t port = gb_gateway_flow_port(id, hev_config_get_socks5_server()->port);\n    if (!port) return;\n    hev_socks5_session_run_selected(self, port);\n    gb_gateway_flow_release(id);\n}\n\nvoid\nhev_socks5_session_terminate (HevSocks5Session *self)')
    main=work/'src/hev-main.c'
    replace(main,'#include "hev-main.h"','#include "hev-main.h"\nextern int gb_internet_tunnel_before_run(void);\nextern void gb_internet_tunnel_after_run(void);')
    replace(main,'    hev_socks5_tunnel_run ();','    if (gb_internet_tunnel_before_run()) hev_socks5_tunnel_run ();\n    gb_internet_tunnel_after_run();')
    run(['make','-j4','static','CC=clang','AR=ar','CFLAGS=-mmacosx-version-min=14.0','REV_ID='+LOCK['components']['hev-socks5-tunnel']['commit']],work)
    output=artifacts/'macos';output.mkdir(parents=True,exist_ok=True)
    objects=[]
    for name in ('gateway_pool','tunnel_adapter'):
        obj=output/(name+'.o');run(['clang','-O2','-fPIC','-mmacosx-version-min=14.0','-I',NATIVE/'include','-I',work/'src','-c',NATIVE/(name+'.c'),'-o',obj]);objects.append(obj)
    libs=[work/'bin/libhev-socks5-tunnel.a',work/'third-part/yaml/bin/libyaml.a',work/'third-part/lwip/bin/liblwip.a',work/'third-part/hev-task-system/bin/libhev-task-system.a']
    run(['libtool','-static','-o',output/'libgalaxybridge_internet.a',*objects,*libs])
    shutil.copy2(NATIVE/'include/galaxybridge_internet.h',output/'galaxybridge_internet.h')
    (output/'build-proof.json').write_text(json.dumps({'source_lock_sha256':hashlib.sha256((NATIVE/'upstream.lock.json').read_bytes()).hexdigest(),'library_sha256':hashlib.sha256((output/'libgalaxybridge_internet.a').read_bytes()).hexdigest(),'network_acceptance':'not-run'},indent=2)+'\n')
def android(cache,artifacts,ndk,abis):
    work=cache/'build-android'
    if work.exists():shutil.rmtree(work)
    sources('hev-socks5-server',work,cache)
    (work/'src/hev-jni.c').unlink()
    shutil.copy2(NATIVE/'android_gateway_jni.c',work/'src/gb-internet-jni.c')
    path=work/'src/core/src/hev-socks5-server.c'
    text=path.read_text(); text='#include <errno.h>\n#ifdef __ANDROID__\nextern int gb_android_bind_socket(int);\nextern void gb_android_upstream_failure(int,int);\n#endif\n'+text;path.write_text(text)
    replace(path,'    klass = HEV_OBJECT_GET_CLASS (self);\n    res = klass->binder','''#ifdef __ANDROID__
    if (gb_android_bind_socket(fd) < 0) { hev_task_del_fd(hev_task_self(), fd); close(fd); return -1; }
#endif
    klass = HEV_OBJECT_GET_CLASS (self);
    res = klass->binder''')
    replace(path,'    self->fds[0] = fd;\n\n    if (!addr)','''#ifdef __ANDROID__
    if (gb_android_bind_socket(fd) < 0) { hev_task_del_fd(hev_task_self(), fd); close(fd); return -1; }
#endif
    self->fds[0] = fd;

    if (!addr)''')
    replace(path,'        LOG_E ("%p socks5 server socket stream", self);','''#ifdef __ANDROID__
        gb_android_upstream_failure(1, errno);
#endif
        LOG_E ("%p socks5 server socket stream", self);''')
    replace(path,'    res = klass->binder (HEV_SOCKS5 (self), fd, (struct sockaddr *)addr);\n    if (res < 0) {','''    res = klass->binder (HEV_SOCKS5 (self), fd, (struct sockaddr *)addr);
    if (res < 0) {
#ifdef __ANDROID__
        gb_android_upstream_failure(3, errno);
#endif''')
    replace(path,'        LOG_I ("%p socks5 server connect", self);','''#ifdef __ANDROID__
        gb_android_upstream_failure(4, errno);
#endif
        LOG_I ("%p socks5 server connect", self);''')
    factory=work/'src/hev-socket-factory.c'
    factory.write_text('#ifdef __ANDROID__\nextern void gb_android_listener_ready(int);\n#endif\n'+factory.read_text())
    replace(factory,'#ifdef SO_REUSEPORT','#if 0 /* private single worker: never share a listener port */')
    replace(factory,'    return fd;\n\nexit_close:', '#ifdef __ANDROID__\n    gb_android_listener_ready(fd);\n#endif\n    return fd;\n\nexit_close:')
    path=work/'Android.mk';replace(path,'LOCAL_MODULE    := hev-socks5-server','LOCAL_MODULE    := galaxybridge_internet');path.write_text(path.read_text().replace('include $(BUILD_SHARED_LIBRARY)','LOCAL_LDLIBS += -landroid -llog\nLOCAL_LDFLAGS += -Wl,--wrap=getaddrinfo\ninclude $(BUILD_SHARED_LIBRARY)'))
    run([ndk/'ndk-build','-j4','NDK_PROJECT_PATH='+str(work),'APP_BUILD_SCRIPT='+str(work/'Android.mk'),'NDK_APPLICATION_MK='+str(work/'Application.mk'),'APP_ABI='+' '.join(abis),'NDK_OUT='+str(cache/'ndk-objects'),'NDK_LIBS_OUT='+str(artifacts/'android')],work)
    proof={abi:hashlib.sha256((artifacts/'android'/abi/'libgalaxybridge_internet.so').read_bytes()).hexdigest() for abi in abis}
    (artifacts/'android/build-proof.json').write_text(json.dumps({'sha256':proof,'ndk':ndk.name,'device_acceptance':'not-run'},indent=2)+'\n')
def main():
    p=argparse.ArgumentParser();p.add_argument('--platform',choices=['macos','android','all'],default='all');p.add_argument('--cache',type=pathlib.Path,default=ROOT/'out/internet-runtime');p.add_argument('--ndk',type=pathlib.Path);p.add_argument('--abis',default='arm64-v8a,x86_64');args=p.parse_args()
    cache=args.cache.resolve()
    if not cache.is_relative_to(ROOT/'out'):raise SystemExit('cache must stay under repository out/')
    artifacts=cache/'artifacts';artifacts.mkdir(parents=True,exist_ok=True)
    shutil.copy2(NATIVE/'THIRD_PARTY_NOTICES.txt',artifacts/'THIRD_PARTY_NOTICES.txt')
    if args.platform in ('macos','all'):macos(cache,artifacts)
    if args.platform in ('android','all'):
        ndk=args.ndk or pathlib.Path(os.environ.get('ANDROID_NDK_HOME',pathlib.Path.home()/'Library/Android/sdk/ndk/29.0.14206865'))
        if not (ndk/'ndk-build').is_file():raise SystemExit('Android NDK required; pass --ndk')
        android(cache,artifacts,ndk,args.abis.split(','))
if __name__=='__main__':main()
