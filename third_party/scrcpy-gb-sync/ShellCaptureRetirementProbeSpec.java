package com.genymobile.scrcpy;
import java.lang.reflect.*;
import java.io.*;
import java.util.*;
public final class ShellCaptureRetirementProbeSpec {
    public static void main(String[] args) throws Exception {
        if (args.length == 1 && args[0].equals("invalid-utf8")) { System.out.write(new byte[] {(byte)0xc3, (byte)0x28}); return; }
        if (args.length == 1 && args[0].equals("valid")) { System.out.print("PID ARGS\n1 init\n"); return; }
        if (args.length == 1 && args[0].equals("overflow")) {
            byte[] bytes = new byte[8192]; Arrays.fill(bytes, (byte)'x');
            for (int i=0; i<1025; i++) System.out.write(bytes);
            System.out.flush(); return;
        }
        Method read = ShellCapabilityBridge.class.getDeclaredMethod("fixedRead", String[].class); read.setAccessible(true);
        String[] command = {System.getProperty("java.home")+"/bin/java", "-cp", System.getProperty("java.class.path"),
            ShellCaptureRetirementProbeSpec.class.getName(), "overflow"};
        boolean rejected = false;
        try { read.invoke(null, (Object)command); }
        catch (InvocationTargetException e) { if (!(e.getCause() instanceof IOException)) throw e; rejected = true; }
        if (!rejected) throw new AssertionError("bounded process inventory silently accepted truncated output as complete");
        System.out.println("PASS bounded process output cannot manufacture an absence proof");
        command[command.length-1]="invalid-utf8"; rejected=false;
        try { read.invoke(null, (Object)command); }
        catch (InvocationTargetException e) { if (!(e.getCause() instanceof IOException)) throw e; rejected=true; }
        if (!rejected) throw new AssertionError("invalid UTF-8 silently repaired inside authoritative inventory");
        command[command.length-1]="valid";
        assert read.invoke(null, (Object)command).equals("PID ARGS\n1 init\n") : "complete normal output is preserved";
        verifyOwnedCaptureLifetime();
        verifyCaptureProof();
        verifyRepeatedProof();
        verifyTypedOptions();
        verifyOwnedResourceRelease();
    }
    private static void verifyOwnedCaptureLifetime() throws Exception {
        Class<?> kind;
        try { kind=Class.forName("com.genymobile.scrcpy.ShellCapabilityBridge$OwnedCaptureLifetime"); }
        catch (ClassNotFoundException absent) { throw new AssertionError("raw capture has no bounded independent owner lifetime",absent); }
        Constructor<?> constructor=kind.getDeclaredConstructor(InputStream.class,long.class,long.class,Runnable.class);
        constructor.setAccessible(true);
        java.util.concurrent.CountDownLatch expired=new java.util.concurrent.CountDownLatch(1);
        PipedInputStream input=new PipedInputStream(); PipedOutputStream output=new PipedOutputStream(input);
        AutoCloseable lease=(AutoCloseable)constructor.newInstance(input,1000L,5L,(Runnable)expired::countDown);
        for(int i=0;i<8;i++) { output.write(126); output.flush(); Thread.sleep(150); assert expired.getCount()==1 : "healthy idle capture expired despite heartbeats"; }
        assert expired.await(2000,java.util.concurrent.TimeUnit.MILLISECONDS) : "stalled open stdin must expire independently of media sockets";
        lease.close(); output.close(); input.close();
        java.util.concurrent.CountDownLatch eof=new java.util.concurrent.CountDownLatch(1);
        lease=(AutoCloseable)constructor.newInstance(new ByteArrayInputStream(new byte[0]),1000L,5L,(Runnable)eof::countDown);
        assert eof.await(200,java.util.concurrent.TimeUnit.MILLISECONDS) : "owner EOF must retire promptly"; lease.close();
        java.util.concurrent.atomic.AtomicInteger callbacks=new java.util.concurrent.atomic.AtomicInteger();
        input=new PipedInputStream(); output=new PipedOutputStream(input);
        lease=(AutoCloseable)constructor.newInstance(input,80L,5L,(Runnable)callbacks::incrementAndGet);
        lease.close(); Thread.sleep(120); output.close(); input.close(); Thread.sleep(10);
        assert callbacks.get()==0 : "normal server exit must cancel lifetime callback";
        System.out.println("PASS healthy idle, stalled stdin deadline, owner EOF and normal-exit cancellation");
    }
    private static String state(int scid, String snapshot) throws Exception {
        Method method;
        try { method = ShellCapabilityBridge.class.getDeclaredMethod("captureRetirementState", int.class, String.class); }
        catch (NoSuchMethodException missing) { throw new AssertionError("prepared broker cannot attest exact ADB capture absence", missing); }
        method.setAccessible(true);
        try { return (String)method.invoke(null, scid, snapshot); }
        catch (InvocationTargetException error) {
            if (error.getCause() instanceof Exception) throw (Exception)error.getCause(); throw error;
        }
    }
    private static void rejectSnapshot(int scid, String snapshot) throws Exception {
        boolean denied=false;
        try { state(scid, snapshot); } catch (IOException | IllegalArgumentException expected) { denied=true; }
        if (!denied) throw new AssertionError("ambiguous inventory was accepted as proof");
    }
    private static void verifyCaptureProof() throws Exception {
        String empty="PID ARGS\n1 /system/bin/init\n";
        assert state(18, empty).equals("absent") : "complete inventory can attest absence";
        assert state(18, "PID COMMAND\n1 init\n").equals("absent") : "alternate toybox header";
        String server="42 app_process / com.genymobile.scrcpy.Server 4.1 scid=00000012\n";
        assert state(18, empty+server).equals("present") : "exact raw producer blocks handoff";
        assert state(18, empty+"42 com.genymobile.scrcpy.ShellCapabilityBridge$ChildMain scrcpy --owner-lease 4.1 scid=00000012\n").equals("present") : "owner-leased raw producer blocks handoff";
        assert state(19, empty+server).equals("absent") : "sibling capture is isolated";
        assert state(18, empty+"42 com.genymobile.scrcpy.ShellCapabilityBridge$ChildMain scrcpy 4.1 scid=00000012\n").equals("present") : "same SCID shell child blocks overlap";
        assert state(18, empty+"42 com.genymobile.scrcpy.CleanUp app_process / com.genymobile.scrcpy.Server 4.1 scid=00000012\n").equals("present") : "cleanup still owns retirement";
        assert state(18, empty+"42 example.com.genymobile.scrcpy.Server scid=00000012\n").equals("absent") : "class token must be exact";
        assert state(18, empty+"42 com.genymobile.scrcpy.Server scid=00000120\n").equals("absent") : "SCID token must be exact";
        rejectSnapshot(0, empty); rejectSnapshot(-1, empty);
        rejectSnapshot(18, ""); rejectSnapshot(18, "PID ARGS\n");
        rejectSnapshot(18, "PID ARGS\n1 init");
        rejectSnapshot(18, "PID ARGS\n42 init\n");
        rejectSnapshot(18, empty+"broken row\n");
        rejectSnapshot(18, empty+"1 duplicate pid\n");
        rejectSnapshot(18, empty+"42 com.genymobile.scrcpy.Server scid=00000012;other\n");
        System.out.println("PASS exact capture process identity, sibling isolation, complete inventory and malformed-input rejection");
    }
    private static void verifyRepeatedProof() throws Exception {
        Class<?> inventory=Class.forName("com.genymobile.scrcpy.ShellCapabilityBridge$CaptureInventory");
        Method confirm=ShellCapabilityBridge.class.getDeclaredMethod("confirmCaptureAbsent",int.class,inventory); confirm.setAccessible(true);
        String absent="PID ARGS\n1 init\n", present=absent+"42 com.genymobile.scrcpy.Server scid=00000012\n";
        int[] count={0};
        Object good=Proxy.newProxyInstance(inventory.getClassLoader(),new Class<?>[]{inventory},(proxy,method,args)->{ count[0]++; return absent; });
        confirm.invoke(null,18,good);
        assert count[0]==5 : "a single absent snapshot cannot settle ownership";
        count[0]=0;
        Object changing=Proxy.newProxyInstance(inventory.getClassLoader(),new Class<?>[]{inventory},(proxy,method,args)->++count[0]==2 ? present : absent);
        boolean rejected=false;
        try { confirm.invoke(null,18,changing); } catch (InvocationTargetException error) { rejected=error.getCause() instanceof IOException; }
        assert rejected && count[0]==2 : "a reappearing exact producer cannot pass an absence proof";
        count[0]=0;
        Object failing=Proxy.newProxyInstance(inventory.getClassLoader(),new Class<?>[]{inventory},(proxy,method,args)->{ if (++count[0]==2) throw new IOException("inventory unavailable"); return absent; });
        rejected=false;
        try { confirm.invoke(null,18,failing); } catch (InvocationTargetException error) { rejected=error.getCause() instanceof IOException; }
        assert rejected && count[0]==2 : "read failure cannot stand in for absence";
        System.out.println("PASS five fresh absence samples; changed owner and read failure remain fenced");
    }
    private static void verifyTypedOptions() throws Exception {
        Class<?> query;
        try { query=Class.forName("com.genymobile.scrcpy.ShellCapabilityBridge$RetirementQuery"); }
        catch (ClassNotFoundException missing) { throw new AssertionError("broker lacks typed capture/controller retirement queries",missing); }
        Method parse=query.getDeclaredMethod("parse",Map.class); parse.setAccessible(true);
        Map<String,Object> fields=new HashMap<>(); fields.put("kind",0);
        assert parse.invoke(null,fields)!=null : "support negotiation is read-only";
        fields.put("kind",1); fields.put("scid",18);
        assert parse.invoke(null,fields)!=null : "typed exact capture";
        fields.put("kind",2); fields.put("scid",0); fields.put("pid",42); fields.put("process_start_ticks",123456L);
        assert parse.invoke(null,fields)!=null : "typed exact display controller";
        fields.put("kind",3);
        assert parse.invoke(null,fields)!=null : "typed composite display controller requires its own proof kind";
        for (String key : Arrays.asList("kind","scid","pid","process_start_ticks")) {
            Map<String,Object> invalid=new HashMap<>(fields); invalid.put(key,"1");
            boolean rejected=false;
            try { parse.invoke(null,invalid); } catch (InvocationTargetException error) { rejected=error.getCause() instanceof IllegalArgumentException; }
            assert rejected : "query scalar coercion accepted";
        }
        fields.put("command","kill"); boolean rejected=false;
        try { parse.invoke(null,fields); } catch (InvocationTargetException error) { rejected=error.getCause() instanceof IllegalArgumentException; }
        assert rejected : "retirement verifier accepted arbitrary command";
        fields.remove("command"); fields.put("pid",1); rejected=false;
        try { parse.invoke(null,fields); } catch (InvocationTargetException error) { rejected=error.getCause() instanceof IllegalArgumentException; }
        assert rejected : "init process is not a captured display controller";
        verifyControllerIdentity();
        System.out.println("PASS typed retirement support/capture/controller queries reject coercions, invalid targets and arbitrary commands");
    }
    private static String controllerState(int pid,long ticks,String stat) throws Exception {
        Method state=ShellCapabilityBridge.class.getDeclaredMethod("controllerRetirementState",int.class,long.class,String.class);state.setAccessible(true);
        try {return (String)state.invoke(null,pid,ticks,stat);}
        catch (InvocationTargetException error) {if(error.getCause() instanceof Exception)throw (Exception)error.getCause();throw error;}
    }
    private static void verifyControllerIdentity() throws Exception {
        StringBuilder fields=new StringBuilder("42 (synthetic owner) S");
        for(int i=1;i<19;i++)fields.append(" 0");fields.append(" 123456\n");
        String live=fields.toString();
        assert controllerState(42,123456,live).equals("present") : "live same PID/start cannot settle";
        assert controllerState(42,123455,live).equals("absent") : "reused PID cannot retain an unrelated owner";
        assert controllerState(42,123456,null).equals("absent") : "a missing proc entry confirms its exact owner gone";
        assert controllerState(42,123456,live.replace(") S",") Z")).equals("absent") : "zombie cannot change a panel";
        for(String malformed:Arrays.asList("", "42 bad", live.replace("42 (","43 ("),live.replace("123456","not-time"))) {
            boolean rejected=false;
            try {controllerState(42,123456,malformed);}catch(IOException|IllegalArgumentException expected){rejected=true;}
            assert rejected : "malformed stat was accepted as absence";
        }
        System.out.println("PASS exact display-controller PID/start lifetime, PID reuse and malformed proc rejection");
    }
    private static boolean release(java.io.File directory,String id,String checksum,byte[] bytes) throws Exception {
        Method method;
        try {method=ShellCapabilityBridge.class.getDeclaredMethod("releasePrivacyResource",java.io.File.class,String.class,String.class,byte[].class);}
        catch(NoSuchMethodException missing){throw new AssertionError("retired controller has no scoped runtime resource cleanup",missing);}
        method.setAccessible(true);
        try{return (Boolean)method.invoke(null,directory,id,checksum,bytes);}
        catch(InvocationTargetException error){if(error.getCause() instanceof Exception)throw (Exception)error.getCause();throw error;}
    }
    private static void verifyOwnedResourceRelease() throws Exception {
        java.nio.file.Path directory=java.nio.file.Files.createTempDirectory("gb-owned-privacy-resource-");
        try {
            String id="69830b65-6352-4b3a-8a21-70bcda45787e";
            byte[] bytes="synthetic known runtime".getBytes(java.nio.charset.StandardCharsets.UTF_8);
            StringBuilder checksum=new StringBuilder();
            for(byte value:java.security.MessageDigest.getInstance("SHA-256").digest(bytes))checksum.append(String.format(java.util.Locale.ROOT,"%02x",value&255));
            java.nio.file.Path file=directory.resolve("galaxybridge-privacy-"+id+".jar");
            java.nio.file.Path sibling=directory.resolve("galaxybridge-privacy-181892ff-7429-4d94-95b6-f425e01f4b06.jar");
            java.nio.file.Files.write(file,bytes);java.nio.file.Files.write(sibling,bytes);
            assert release(directory.toFile(),id,checksum.toString(),bytes);
            assert !java.nio.file.Files.exists(file) && java.nio.file.Files.exists(sibling) : "cleanup touched another owner";
            assert release(directory.toFile(),id,checksum.toString(),bytes) : "exact cleanup must be idempotent";
            byte[] unrelated="unrelated payload".getBytes(java.nio.charset.StandardCharsets.UTF_8);java.nio.file.Files.write(file,unrelated);
            boolean rejected=false;
            try{release(directory.toFile(),id,checksum.toString(),bytes);}catch(IOException|IllegalArgumentException expected){rejected=true;}
            assert rejected && java.util.Arrays.equals(java.nio.file.Files.readAllBytes(file),unrelated) : "non-runtime bytes were removed";
            java.nio.file.Files.delete(file);java.nio.file.Files.createSymbolicLink(file,sibling);
            rejected=false;try{release(directory.toFile(),id,checksum.toString(),bytes);}catch(IOException|IllegalArgumentException expected){rejected=true;}
            assert rejected && java.nio.file.Files.exists(sibling) : "symlink escaped owned resource path";
            rejected=false;try{release(directory.toFile(),"../unrelated",checksum.toString(),bytes);}catch(IOException|IllegalArgumentException expected){rejected=true;}
            assert rejected : "remote path was accepted instead of an ownership UUID";
            System.out.println("PASS scoped privacy runtime cleanup: exact UUID/hash, sibling preservation, idempotency, unrelated bytes and symlink rejection");
        } finally {
            try(java.util.stream.Stream<java.nio.file.Path> paths=java.nio.file.Files.walk(directory)){
                for(java.nio.file.Path path:(Iterable<java.nio.file.Path>)paths.sorted(java.util.Comparator.reverseOrder())::iterator)java.nio.file.Files.deleteIfExists(path);
            }
        }
    }

}
