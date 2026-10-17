#!/usr/bin/env python3
"""Create an optional unsigned installer; never installs or requests sudo."""
import os
import argparse, hashlib, json, pathlib, plistlib, re, shutil, struct, subprocess, tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
LABEL='com.xopmc.GalaxyBridge.NetworkHelper'
BIN='/Library/PrivilegedHelperTools/'+LABEL
def run(args,**kw):return subprocess.run([str(x) for x in args],check=True,**kw)
def program_fingerprint(data):
    if len(data)<32 or len(data)>512*1024*1024: raise ValueError('invalid executable')
    magic,_,_,_,commands,size,_,_=struct.unpack_from('<8I',data)
    if magic!=0xfeedfacf or commands>4096 or size>len(data)-32: raise ValueError('only thin signed 64-bit Mach-O is supported')
    normalized=bytearray(data);cursor=32;signature=None;linkedit=None
    for _ in range(commands):
        if cursor+8>32+size: raise ValueError('invalid load commands')
        kind,length=struct.unpack_from('<II',data,cursor)
        if length<8 or length>32+size-cursor: raise ValueError('invalid load command size')
        if kind==0x1d:
            if signature is not None or length!=16: raise ValueError('invalid code signature command')
            offset,count=struct.unpack_from('<II',data,cursor+8)
            if offset<32+size or offset+count!=len(data): raise ValueError('invalid code signature extent')
            signature=offset;struct.pack_into('<II',normalized,cursor+8,0,0)
        if kind==0x19 and length>=72 and data[cursor+8:cursor+24].rstrip(b'\0')==b'__LINKEDIT':linkedit=cursor
        cursor+=length
    if cursor!=32+size or signature is None or linkedit is None: raise ValueError('signed executable required')
    fileoff=struct.unpack_from('<Q',data,linkedit+40)[0]
    if fileoff>signature:raise ValueError('invalid LINKEDIT')
    struct.pack_into('<Q',normalized,linkedit+32,0)
    struct.pack_into('<Q',normalized,linkedit+48,signature-fileoff)
    return hashlib.sha256(b'GalaxyBridgeProgramFingerprint-v1\0'+normalized[:signature]).hexdigest()
def main():
 from build_path_privacy import path_maps
 p=argparse.ArgumentParser();p.add_argument('--app',required=True,type=pathlib.Path);p.add_argument('--output',type=pathlib.Path,default=ROOT/'out/internet-runtime/GalaxyBridge-Network-Helper.pkg');p.add_argument('--identity',default='-');a=p.parse_args()
 app=a.app.resolve();run(['codesign','--verify','--strict',app]);detail=run(['codesign','-d','--verbose=4',app],capture_output=True,text=True)
 info=plistlib.loads((app/'Contents/Info.plist').read_bytes());executable=info['CFBundleExecutable']
 if pathlib.Path(executable).name!=executable or executable.startswith('.'):raise SystemExit('Invalid executable name')
 fingerprint=program_fingerprint((app/'Contents/MacOS'/executable).read_bytes())
 output=a.output.resolve();output.parent.mkdir(parents=True,exist_ok=True)
 with tempfile.TemporaryDirectory(prefix='gb-network-helper-',dir=output.parent) as tmp:
  work=pathlib.Path(tmp);payload=work/'root';tools=payload/'Library/PrivilegedHelperTools';daemons=payload/'Library/LaunchDaemons';tools.mkdir(parents=True);daemons.mkdir(parents=True)
  helper=tools/LABEL;sources=ROOT/'macos/GalaxyBridgeNetworkHelper'
  path_flags=['-ffile-prefix-map='+source+'='+destination for source,destination in path_maps(ROOT,work,os.environ)]
  run(['clang','-g0',*path_flags,'-std=c11','-O2','-Wall','-Wextra','-Werror','-mmacosx-version-min=14.0','-I',sources,sources/'GBNetworkLease.c',sources/'GBRouteLease.c',sources/'GBCodeTrust.c',sources/'GBProgramFingerprint.c',sources/'GBNetworkDaemon.c','-framework','Security','-framework','SystemConfiguration','-framework','CoreFoundation','-lbsm','-o',helper])
  run(['xcrun','strip','-S',helper])
  run(['codesign','--force','--sign',a.identity,helper]);helper.chmod(0o755)
  pin=tools/(LABEL+'.cdhash.program-sha256');pin.write_text(fingerprint+'\n');pin.chmod(0o600)
  daemon={'Label':LABEL,'ProgramArguments':[BIN],'Sockets':{'Control':{'SockPathName':'/var/run/GalaxyBridgeNetworkHelper.sock','SockType':'seqpacket','SockPathMode':0o666}},'ExitTimeOut':20,'ProcessType':'Interactive'}
  guardian={'Label':LABEL+'.guardian','ProgramArguments':[BIN,'--guardian'],'RunAtLoad':True,'StartInterval':5,'ProcessType':'Background','ExitTimeOut':10}
  for name,value in [(LABEL,daemon),(LABEL+'.guardian',guardian)]:
   f=daemons/(name+'.plist');f.write_bytes(plistlib.dumps(value));f.chmod(0o644)
  scripts=work/'scripts';scripts.mkdir();post=scripts/'postinstall'
  post.write_text('#!/bin/sh\nset -eu\n'+f'/usr/sbin/chown root:wheel "{BIN}" "{BIN}.cdhash.program-sha256" /Library/LaunchDaemons/{LABEL}.plist /Library/LaunchDaemons/{LABEL}.guardian.plist\n'+f'/bin/chmod 755 "{BIN}"\n/bin/chmod 600 "{BIN}.cdhash.program-sha256"\n'+f'"{BIN}" --approve-app\n'+''.join(f'/bin/launchctl bootout system/{name} >/dev/null 2>&1 || true\n/bin/launchctl bootstrap system /Library/LaunchDaemons/{name}.plist\n' for name in [LABEL+'.guardian',LABEL])+'exit 0\n');post.chmod(0o755)
  run(['pkgbuild','--root',payload,'--scripts',scripts,'--identifier',LABEL+'.installer','--version','0.1.2','--ownership','recommended',output])
 (output.with_suffix('.json')).write_text(json.dumps({'program_sha256':fingerprint,'package_sha256':hashlib.sha256(output.read_bytes()).hexdigest(),'installation_tested':False,'network_mutation_tested':False},indent=2)+'\n')
 print(output)
if __name__=='__main__':main()
