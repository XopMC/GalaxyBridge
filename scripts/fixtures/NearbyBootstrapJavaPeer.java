import com.xopmc.galaxybridge.transport.NearbyBootstrapCrypto;
import java.io.*;
import java.security.*;
import java.security.spec.ECGenParameterSpec;
import java.util.Base64;

public class NearbyBootstrapJavaPeer {
    public static void main(String[] args) throws Exception {
        BufferedReader input=new BufferedReader(new InputStreamReader(System.in));
        NearbyBootstrapCrypto.Hello mac=NearbyBootstrapCrypto.Hello.decode(Base64.getDecoder().decode(input.readLine()));
        KeyPairGenerator keys=KeyPairGenerator.getInstance("EC");keys.initialize(new ECGenParameterSpec("secp256r1"));
        NearbyBootstrapCrypto.Agreement phone=new NearbyBootstrapCrypto.Agreement(1,"neutral-phone",mac.context,keys.generateKeyPair());
        byte[] token=new byte[32];java.util.Arrays.fill(token,(byte)17);
        NearbyBootstrapCrypto.Session session=phone.complete(mac,mac.identity,token);
        System.out.println(Base64.getEncoder().encodeToString(phone.hello().encode()));System.out.flush();
        byte[] message=session.open(Base64.getDecoder().decode(input.readLine()));
        if(!new String(message,java.nio.charset.StandardCharsets.UTF_8).equals("cross-platform credentials"))throw new AssertionError("plaintext");
        System.out.println(Base64.getEncoder().encodeToString(session.seal("Android ready".getBytes(java.nio.charset.StandardCharsets.UTF_8))));System.out.flush();
    }
}
