package com.xopmc.galaxybridge.transport;

import java.io.*;
import java.math.BigInteger;
import java.nio.*;
import java.nio.charset.*;
import java.security.*;
import java.security.interfaces.ECPublicKey;
import java.security.spec.*;
import java.util.*;
import javax.crypto.*;
import javax.crypto.spec.*;

/** Paired-identity authenticated BLE bootstrap; never a replacement for channel TLS. */
public final class NearbyBootstrapCrypto {
    private NearbyBootstrapCrypto() {}
    public static final class Hello {
        public final int role;
        public final String deviceID;
        public final byte[] context,identity,ephemeral,nonce,signature;
        public Hello(int role,String id,byte[] context,byte[] identity,byte[] ephemeral,byte[] nonce,byte[] signature) {
            this.role=role;deviceID=id;this.context=context.clone();this.identity=identity.clone();this.ephemeral=ephemeral.clone();this.nonce=nonce.clone();this.signature=signature.clone();
        }
        public byte[] transcript() { return fields(text("GalaxyBridge/Nearby/Hello/v1"),new byte[]{(byte)role},text(deviceID),context,identity,ephemeral,nonce); }
        public byte[] encode() { return fields(new byte[]{1},new byte[]{(byte)role},text(deviceID),context,identity,ephemeral,nonce,signature); }
        public static Hello decode(byte[] wire) throws GeneralSecurityException {
            if(wire.length>8192)throw failure();
            try {
                DataInputStream in=new DataInputStream(new ByteArrayInputStream(wire));
                byte[] v=field(in),r=field(in),id=field(in);
                if(!Arrays.equals(v,new byte[]{1})||r.length!=1||(r[0]!=0&&r[0]!=1))throw failure();
                String name=StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(id)).toString();
                Hello h=new Hello(r[0],name,field(in),field(in),field(in),field(in),field(in));
                if(in.available()!=0)throw failure(); return h;
            } catch(IOException e){throw new GeneralSecurityException("invalid_nearby_hello",e);}
        }
        public void validate(byte[] expected) throws GeneralSecurityException {
            if((role!=0&&role!=1)||deviceID.isEmpty()||text(deviceID).length>256||context.length!=32||nonce.length!=32||identity.length!=65||ephemeral.length!=65||signature.length<8||signature.length>80||!MessageDigest.isEqual(identity,expected))throw failure();
            Signature verifier=Signature.getInstance("SHA256withECDSA");verifier.initVerify(publicKey(identity));verifier.update(transcript());if(!verifier.verify(signature))throw failure();
        }
    }
    public static final class Agreement {
        private final int role;
        private final String id;
        private final byte[] context,nonce=new byte[32];
        private final KeyPair identity,ephemeral;
        public Agreement(int role,String id,byte[] context,KeyPair identity) throws GeneralSecurityException {
            this.role=role;this.id=id;this.context=context.clone();this.identity=identity;
            KeyPairGenerator g=KeyPairGenerator.getInstance("EC");g.initialize(new ECGenParameterSpec("secp256r1"));ephemeral=g.generateKeyPair();new SecureRandom().nextBytes(nonce);
        }
        public Hello hello() throws GeneralSecurityException {
            Hello h=new Hello(role,id,context,x963(identity.getPublic()),x963(ephemeral.getPublic()),nonce,new byte[0]);
            Signature s=Signature.getInstance("SHA256withECDSA");s.initSign(identity.getPrivate());s.update(h.transcript());
            Hello result=new Hello(role,id,context,h.identity,h.ephemeral,nonce,s.sign());result.validate(h.identity);return result;
        }
        public Session complete(Hello remote,byte[] expectedIdentity,byte[] token) throws GeneralSecurityException {
            remote.validate(expectedIdentity);
            if(remote.role==role||!Arrays.equals(context,remote.context)||(token!=null&&token.length!=32))throw failure();
            Hello local=hello(),first=role==0?local:remote,second=role==1?local:remote;
            byte[] binding=sha(fields(first.transcript(),second.transcript()));
            byte[] salt=sha(fields(binding,token==null?new byte[0]:token));
            KeyAgreement agreement=KeyAgreement.getInstance("ECDH");agreement.init(ephemeral.getPrivate());agreement.doPhase(publicKey(remote.ephemeral),true);
            byte[] prk=hmac(salt,agreement.generateSecret()),info=text("GalaxyBridge/Nearby/Keys/v1");
            byte[] firstKey=hmac(prk,concat(info,new byte[]{1}));
            byte[] secondKey=hmac(prk,concat(firstKey,info,new byte[]{2}));
            return new Session(role,role==0?firstKey:secondKey,role==0?secondKey:firstKey,binding);
        }
    }
    public static final class Session {
        private final int role;
        private final byte[] send,receive,binding;
        private long sendCounter,receiveCounter;
        private Session(int role,byte[] send,byte[] receive,byte[] binding){this.role=role;this.send=send;this.receive=receive;this.binding=binding;}
        public synchronized byte[] seal(byte[] plain) throws GeneralSecurityException {
            if(plain.length==0||plain.length>8192||sendCounter==Long.MAX_VALUE)throw failure();
            byte[] counter=counter(sendCounter);byte[] encrypted=crypt(Cipher.ENCRYPT_MODE,send,role,counter,plain);sendCounter++;return concat(counter,encrypted);
        }
        public synchronized byte[] open(byte[] frame) throws GeneralSecurityException {
            if(frame.length<25||frame.length>8216||receiveCounter==Long.MAX_VALUE)throw failure();
            byte[] count=Arrays.copyOf(frame,8),expected=counter(receiveCounter);if(!MessageDigest.isEqual(count,expected))throw failure();
            byte[] plain=crypt(Cipher.DECRYPT_MODE,receive,1-role,count,Arrays.copyOfRange(frame,8,frame.length));receiveCounter++;return plain;
        }
        private byte[] crypt(int mode,byte[] key,int direction,byte[] counter,byte[] data) throws GeneralSecurityException {
            Cipher c=Cipher.getInstance("AES/GCM/NoPadding");c.init(mode,new SecretKeySpec(key,"AES"),new GCMParameterSpec(128,concat(new byte[]{0,0,0,(byte)direction},counter)));
            c.updateAAD(concat(binding,new byte[]{(byte)direction},counter));return c.doFinal(data);
        }
    }
    public static byte[] x963(PublicKey key) {
        ECPublicKey p=(ECPublicKey)key;return concat(new byte[]{4},padded(p.getW().getAffineX()),padded(p.getW().getAffineY()));
    }
    private static byte[] padded(BigInteger n){byte[] a=n.toByteArray(),out=new byte[32];int count=Math.min(a.length,32);System.arraycopy(a,a.length-count,out,32-count,count);return out;}
    private static PublicKey publicKey(byte[] bytes) throws GeneralSecurityException {
        if(bytes.length!=65||bytes[0]!=4)throw failure();
        AlgorithmParameters p=AlgorithmParameters.getInstance("EC");p.init(new ECGenParameterSpec("secp256r1"));
        return KeyFactory.getInstance("EC").generatePublic(new ECPublicKeySpec(new ECPoint(new BigInteger(1,Arrays.copyOfRange(bytes,1,33)),new BigInteger(1,Arrays.copyOfRange(bytes,33,65))),p.getParameterSpec(ECParameterSpec.class)));
    }
    private static byte[] field(DataInputStream in) throws IOException,GeneralSecurityException {int n=in.readInt();if(n<0||n>8192||n>in.available())throw failure();byte[] b=new byte[n];in.readFully(b);return b;}
    private static byte[] text(String s){return s.getBytes(StandardCharsets.UTF_8);}
    private static byte[] counter(long n){return ByteBuffer.allocate(8).putLong(n).array();}
    private static byte[] sha(byte[] x)throws GeneralSecurityException{return MessageDigest.getInstance("SHA-256").digest(x);}
    private static byte[] hmac(byte[] k,byte[] data)throws GeneralSecurityException {Mac m=Mac.getInstance("HmacSHA256");m.init(new SecretKeySpec(k,"HmacSHA256"));return m.doFinal(data);}
    private static byte[] fields(byte[]... xs){try{ByteArrayOutputStream b=new ByteArrayOutputStream();DataOutputStream o=new DataOutputStream(b);for(byte[] x:xs){o.writeInt(x.length);o.write(x);}return b.toByteArray();}catch(IOException impossible){throw new AssertionError(impossible);}}
    private static byte[] concat(byte[]...xs){ByteArrayOutputStream b=new ByteArrayOutputStream();for(byte[] x:xs)b.write(x,0,x.length);return b.toByteArray();}
    private static GeneralSecurityException failure(){return new GeneralSecurityException("nearby_authentication_failed");}
}
