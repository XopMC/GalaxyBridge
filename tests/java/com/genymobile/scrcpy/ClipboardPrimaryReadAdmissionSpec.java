package com.genymobile.scrcpy;
import java.util.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

/** Executes the production read admission with observable Android API boundaries. */
public final class ClipboardPrimaryReadAdmissionSpec {
    static final byte KIND_TEXT=1, KIND_PNG=3;
    static final int MAX_PAYLOAD=4*1024*1024;
    static final String ORIGIN_ID="com.xopmc.galaxybridge.clipboard.origin";
    static final String ORIGIN_DIGEST="com.xopmc.galaxybridge.clipboard.origin_digest";
    static final Object imageResolver=new Object();
    static int imageReads;
    static final class PersistableBundle {
        final Map<String,String> values=new HashMap<>();
        String getString(String key) { return values.get(key); }
    }
    static final class ClipDescription {
        long timestamp; boolean sensitive; String[] mimes; PersistableBundle extras=new PersistableBundle();
        ClipDescription(long timestamp,String... mimes) { this.timestamp=timestamp;this.mimes=mimes; }
        long getTimestamp() { return timestamp; }
        int getMimeTypeCount() { return mimes.length; }
        String getMimeType(int index) { return mimes[index]; }
        boolean hasMimeType(String value) { return Arrays.stream(mimes).anyMatch(m -> value.equals("image/*") ? m.startsWith("image/") : m.equals(value)); }
        PersistableBundle getExtras() { return extras; }
    }
    static final class Uri {
        final byte[] image; Uri(byte... data) { image=data; }
        public String toString() { return "content://fixture/image"; }
    }
    static final class ClipData {
        static final class Item {
            final String text;final Uri uri;Item(String text,Uri uri) { this.text=text;this.uri=uri; }
            String getText() { return text; } Uri getUri() { return uri; }
        }
        final Item item;ClipData(Item item) { this.item=item; }
        int getItemCount() { return item==null ? 0 : 1; } Item getItemAt(int index) { return item; }
    }
    static final class ClipboardManager {
        ClipDescription description;ClipData clip;int payloadReads;Runnable afterRead;
        ClipDescription getPrimaryClipDescription() { return description; }
        ClipData getPrimaryClip() { payloadReads++;if(afterRead!=null) { Runnable next=afterRead;afterRead=null;next.run(); } return clip; }
        void text(long time,String text) { description=new ClipDescription(time,"text/plain");clip=new ClipData(new ClipData.Item(text,null)); }
        void image(long time,byte... data) { description=new ClipDescription(time,"image/png");clip=new ClipData(new ClipData.Item(null,new Uri(data))); }
    }
    static final class Snapshot {
        final byte kind;final byte[] content,digest;final long timestamp;final String origin,platformSource;
        Snapshot(byte kind,byte[] content,byte[] digest,long timestamp,String origin,String source) {
            this.kind=kind;this.content=content;this.digest=digest;this.timestamp=timestamp;this.origin=origin;this.platformSource=source;
        }
    }
    static boolean isSensitive(ClipDescription d) { return d.sensitive; }
    static byte[] readImage(Object resolver,Uri uri) { imageReads++;return uri.image; }
    static String clipboardSource(ClipboardManager c) { return "com.android.shell"; }
    static byte[] fingerprint(byte kind,byte[] content) throws Exception {
        MessageDigest digest=MessageDigest.getInstance("SHA-256");digest.update(kind);digest.update((byte)0);return digest.digest(content);
    }
    static String hex(byte[] value) { return java.util.HexFormat.of().formatHex(value); }
    // ACTUAL_PRIMARY_READ_METHODS
    static void require(boolean condition,String message) { if(!condition)throw new AssertionError(message); }
    public static void main(String[] args) {
        ClipboardManager manager=new ClipboardManager();ClipboardSnapshotCache<Snapshot> cache=new ClipboardSnapshotCache<>();
        require(readSnapshot(manager,cache)==null && manager.payloadReads==0,"Empty metadata must not read payload");
        manager.text(100,"synthetic-a");Snapshot first=readSnapshot(manager,cache);
        require(first!=null && manager.payloadReads==1,"New text occurrence must be read");
        for(int i=0;i<100;i++)require(readSnapshot(manager,cache)==first,"Stable text snapshot must stay available");
        require(manager.payloadReads==1,"Unchanged polling reread the full clipboard "+manager.payloadReads+" times");
        manager.text(101,"synthetic-a");Snapshot recopied=readSnapshot(manager,cache);
        require(recopied!=null && recopied!=first && manager.payloadReads==2,"An equal-content user recopy is a new occurrence");
        manager.image(102,(byte)1,(byte)2);Snapshot image=readSnapshot(manager,cache);
        for(int i=0;i<100;i++)require(readSnapshot(manager,cache)==image,"Stable image must remain available");
        require(manager.payloadReads==3 && imageReads==1,"Stable image polling must not reopen the clip/provider");
        manager.image(103,(byte)3,(byte)4);require(readSnapshot(manager,cache)!=image && imageReads==2,"New screenshot must load the full image");
        int beforeSensitive=manager.payloadReads;manager.description.sensitive=true;
        require(readSnapshot(manager,cache)==null && manager.payloadReads==beforeSensitive,"Sensitive clip must not be read");
        manager.description.sensitive=false;require(readSnapshot(manager,cache)!=null && manager.payloadReads==beforeSensitive+1,"Sensitive interval invalidates cached payload");
        manager.text(104,"stale");manager.afterRead=()->manager.text(105,"new");
        require(readSnapshot(manager,cache)==null,"Concurrent new clip must invalidate loaded old data");
        require(new String(readSnapshot(manager,cache).content,StandardCharsets.UTF_8).equals("new"),"Next real occurrence must recover after a race");
        manager.description=null;require(readSnapshot(manager,cache)==null,"Cleared clipboard must drop cached content");
        manager.text(0,"unknown-clock");int beforeUnknown=manager.payloadReads;
        require(readSnapshot(manager,cache)!=null && readSnapshot(manager,cache)!=null && manager.payloadReads==beforeUnknown+2,"Unknown timestamps must retain full polling fallback");
        manager.description=new ClipDescription(106,new String[33]);beforeUnknown=manager.payloadReads;
        require(readSnapshot(manager,cache)==null && manager.payloadReads==beforeUnknown,"Unbounded metadata must fail closed before full read");
        System.out.println("PASS actual clipboard read admission: unchanged metadata skips full reads; text/image changes, deliberate recopy, sensitivity, race recovery and unknown-clock fallback preserved");
    }
}
