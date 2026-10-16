package com.xopmc.galaxybridge.transport;
import org.junit.Test;
import static org.junit.Assert.*;
import java.security.*;
import java.security.spec.ECGenParameterSpec;

public class NearbyBootstrapCryptoTest {
    static KeyPair keys() throws Exception { KeyPairGenerator g=KeyPairGenerator.getInstance("EC");g.initialize(new ECGenParameterSpec("secp256r1"));return g.generateKeyPair(); }
    @Test public void authenticatesBothDirectionsAndRejectsReplayTamperAndForeignKeys() throws Exception {
        KeyPair a=keys(), b=keys(); byte[] context=new byte[32], token=new byte[32]; token[0]=4;
        NearbyBootstrapCrypto.Agreement left=new NearbyBootstrapCrypto.Agreement(0,"mac",context,a);
        NearbyBootstrapCrypto.Agreement right=new NearbyBootstrapCrypto.Agreement(1,"phone",context,b);
        NearbyBootstrapCrypto.Hello lh=left.hello(), rh=right.hello();
        assertArrayEquals(lh.transcript(),NearbyBootstrapCrypto.Hello.decode(lh.encode()).transcript());
        NearbyBootstrapCrypto.Session ls=left.complete(rh,rh.identity,token), rs=right.complete(lh,lh.identity,token);
        byte[] encrypted=ls.seal(new byte[]{1,2,3});assertArrayEquals(new byte[]{1,2,3},rs.open(encrypted));
        assertThrows(GeneralSecurityException.class,()->rs.open(encrypted));
        byte[] next=ls.seal(new byte[]{8});byte[] damaged=next.clone();damaged[damaged.length-1]^=1;
        assertThrows(GeneralSecurityException.class,()->rs.open(damaged)); assertArrayEquals(new byte[]{8},rs.open(next));
        assertArrayEquals(new byte[]{9},ls.open(rs.seal(new byte[]{9})));
        assertThrows(GeneralSecurityException.class,()->left.complete(rh,lh.identity,token));
        assertThrows(GeneralSecurityException.class,()->ls.seal(new byte[8193]));
    }
}
