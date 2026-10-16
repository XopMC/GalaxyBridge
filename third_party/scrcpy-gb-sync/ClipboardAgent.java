package com.genymobile.scrcpy;

import android.content.ClipData;
import android.content.ClipDescription;
import android.content.ClipboardManager;
import android.content.ContentResolver;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.net.Uri;
import android.os.Build;
import android.os.Looper;
import android.os.PersistableBundle;
import com.genymobile.scrcpy.wrappers.ClipboardContentResolver;

import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.io.DataInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.security.MessageDigest;
import java.lang.reflect.Method;
import java.util.Arrays;
import java.util.concurrent.atomic.AtomicBoolean;

/** Polls the complete Android primary clip from scrcpy's shell context. */
public final class ClipboardAgent {
    private static final String ORIGIN_ID = "com.xopmc.galaxybridge.clipboard.origin";
    private static final String ORIGIN_DIGEST = "com.xopmc.galaxybridge.clipboard.origin_digest";
    private static final byte KIND_TEXT = 1;
    private static final byte KIND_PNG = 3;
    private static final int MAX_PAYLOAD = 4 * 1024 * 1024;
    private static final int MAX_SOURCE = 16 * 1024 * 1024;
    private static final long POLL_MILLIS = 350;
    private static ContentResolver imageResolver;
    private static final Method CLIP_SOURCE = clipboardSourceMethod();

    private ClipboardAgent() {}

    public static void main(String... args) {
        if (args.length != 1 || !args[0].matches("[A-Za-z0-9_.-]{1,80}")) {
            System.err.println("Galaxy Bridge clipboard agent requires one bounded socket name");
            System.exit(2);
        }
        try {
            Looper.prepare();
            Workarounds.apply();
            run(args[0]);
        } catch (Throwable error) {
            error.printStackTrace(System.err);
            System.exit(1);
        }
    }

    private static void run(String socketName) throws Exception {
        ClipboardManager clipboard = (ClipboardManager) FakeContext.get().getSystemService(FakeContext.CLIPBOARD_SERVICE);
        if (clipboard == null) throw new IOException("clipboard service unavailable");
        imageResolver = new ClipboardContentResolver(FakeContext.get());
        try (LocalServerSocket server = new LocalServerSocket(socketName);
             LocalSocket socket = server.accept();
             DataOutputStream output = new DataOutputStream(socket.getOutputStream())) {
            DataInputStream input = new DataInputStream(socket.getInputStream());
            output.write(new byte[] {'G', 'B', 'C', '2'});
            output.flush();
            byte[] previousDigest = null;
            long previousTimestamp = Long.MIN_VALUE;
            ClipboardSnapshotCache<Snapshot> cache = new ClipboardSnapshotCache<>();
            ClipboardOriginTracker origins = new ClipboardOriginTracker();
            AtomicBoolean connected = new AtomicBoolean(true);
            Thread commands = new Thread(() -> {
                try {
                    while (connected.get()) readTextCommand(input, clipboard);
                } catch (Exception ignored) {
                    // EOF retires a static clipboard too; no future change is
                    // required to notice that the Mac closed this socket.
                } finally {
                    connected.set(false);
                    try { socket.close(); } catch (IOException ignored) {}
                }
            }, "galaxybridge-clipboard-commands");
            commands.setDaemon(true);
            commands.start();
            while (connected.get() && !Thread.currentThread().isInterrupted()) {
                Snapshot snapshot = readSnapshot(clipboard, cache);
                if (snapshot == null) {
                    previousDigest = null;
                    previousTimestamp = Long.MIN_VALUE;
                } else if (snapshot.timestamp != previousTimestamp || !Arrays.equals(snapshot.digest, previousDigest)) {
                    String source = origins.originFor(snapshot.origin, snapshot.timestamp, snapshot.platformSource);
                    byte[] origin = source == null ? new byte[0] : source.getBytes(java.nio.charset.StandardCharsets.UTF_8);
                    output.writeByte(snapshot.kind);
                    output.writeLong(snapshot.timestamp);
                    output.writeShort(origin.length);
                    output.writeInt(snapshot.content.length);
                    output.write(origin);
                    output.write(snapshot.content);
                    output.flush();
                    previousDigest = snapshot.digest;
                    previousTimestamp = snapshot.timestamp;
                }
                Thread.sleep(POLL_MILLIS);
            }
        }
    }

    private static Snapshot readSnapshot(ClipboardManager clipboard, ClipboardSnapshotCache<Snapshot> cache) {
        try {
            ClipDescription description = clipboard.getPrimaryClipDescription();
            if (description == null || isSensitive(description)) { cache.clear(); return null; }
            ClipData clip = clipboard.getPrimaryClip();
            if (clip == null || clip.getItemCount() == 0) { cache.clear(); return null; }
            ClipData.Item item = clip.getItemAt(0);
            final byte kind;
            final String identity;
            final Uri uri;
            final String text;
            if (description.hasMimeType("image/*") && item.getUri() != null) {
                uri = item.getUri();
                text = null;
                identity = "image:" + uri;
                kind = KIND_PNG;
            } else if (item.getText() != null) {
                text = item.getText().toString();
                if (text.length() > MAX_PAYLOAD) return null;
                uri = null;
                identity = "text:" + text;
                kind = KIND_TEXT;
            } else {
                cache.clear();
                return null;
            }
            final long timestamp = description.getTimestamp();
            // Inspect the complete current primary clip every poll, but do not
            // reopen a provider, decode/compress and hash the same screenshot
            // three times per second while a mirror encoder is running.
            return cache.read(timestamp, identity, () -> {
                byte[] content = kind == KIND_PNG
                        ? readImage(imageResolver, uri)
                        : text.getBytes(java.nio.charset.StandardCharsets.UTF_8);
                if (content == null || content.length == 0 || content.length > MAX_PAYLOAD) return null;
                ClipDescription latest = clipboard.getPrimaryClipDescription();
                if (latest == null || isSensitive(latest)
                        || (timestamp > 0 && latest.getTimestamp() != timestamp)) return null;
                byte[] digest = fingerprint(kind, content);
                PersistableBundle extras = description.getExtras();
                String origin = extras == null ? null : extras.getString(ORIGIN_ID);
                if (origin != null && (origin.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 256
                        || !hex(digest).equals(extras.getString(ORIGIN_DIGEST)))) origin = null;
                String source = origin == null ? null : clipboardSource(clipboard);
                ClipDescription current = clipboard.getPrimaryClipDescription();
                if (current == null || isSensitive(current)
                        || (timestamp > 0 && current.getTimestamp() != timestamp)) return null;
                return new Snapshot(kind, content, digest, timestamp, origin, source);
            });
        } catch (RuntimeException error) {
            return null;
        } catch (Exception error) {
            return null;
        }
    }

    private static Method clipboardSourceMethod() {
        try { return ClipboardManager.class.getDeclaredMethod("getPrimaryClipSource"); }
        catch (ReflectiveOperationException | RuntimeException ignored) { return null; }
    }

    private static String clipboardSource(ClipboardManager clipboard) {
        if (CLIP_SOURCE == null) return null;
        try {
            Object value = CLIP_SOURCE.invoke(clipboard);
            return value instanceof String ? (String) value : null;
        } catch (ReflectiveOperationException | RuntimeException ignored) { return null; }
    }

    private static byte[] fingerprint(byte kind, byte[] content) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        digest.update(kind); digest.update((byte) 0); digest.update(content);
        return digest.digest();
    }

    private static String hex(byte[] bytes) {
        StringBuilder result = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) result.append(String.format(java.util.Locale.ROOT, "%02x", value & 0xff));
        return result.toString();
    }

    private static void readTextCommand(DataInputStream input, ClipboardManager clipboard) throws Exception {
        int kind = input.readUnsignedByte();
        long timestamp = input.readLong();
        int originLength = input.readUnsignedShort();
        int length = input.readInt();
        if (kind != KIND_TEXT || timestamp != 0 || originLength < 1 || originLength > 256
                || length < 1 || length > 262139) throw new IOException("invalid clipboard command");
        byte[] origin = new byte[originLength], content = new byte[length];
        input.readFully(origin); input.readFully(content);
        java.nio.charset.CharsetDecoder decoder = java.nio.charset.StandardCharsets.UTF_8.newDecoder();
        String source = decoder.decode(java.nio.ByteBuffer.wrap(origin)).toString();
        String text = decoder.decode(java.nio.ByteBuffer.wrap(content)).toString();
        ClipData clip = ClipData.newPlainText("Galaxy Bridge", text);
        PersistableBundle extras = new PersistableBundle();
        extras.putString(ORIGIN_ID, source);
        extras.putString(ORIGIN_DIGEST, hex(fingerprint(KIND_TEXT, content)));
        clip.getDescription().setExtras(extras);
        clipboard.setPrimaryClip(clip);
    }

    private static boolean isSensitive(ClipDescription description) {
        if (Build.VERSION.SDK_INT < 33) return false;
        PersistableBundle extras = description.getExtras();
        return extras != null && extras.getBoolean(ClipDescription.EXTRA_IS_SENSITIVE, false);
    }

    private static byte[] readImage(ContentResolver resolver, Uri uri) throws IOException {
        if (!ContentResolver.SCHEME_CONTENT.equals(uri.getScheme())) return null;
        byte[] encoded;
        try (InputStream input = resolver.openInputStream(uri)) {
            if (input == null) return null;
            encoded = readBounded(input, MAX_SOURCE);
        }
        BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(encoded, 0, encoded.length, bounds);
        if (!plausible(bounds.outWidth, bounds.outHeight)) return null;
        if ("image/png".equals(bounds.outMimeType) && encoded.length <= MAX_PAYLOAD) return encoded;
        int sample = 1;
        while ((long) (bounds.outWidth / sample) * (bounds.outHeight / sample) > 4_000_000L) sample *= 2;
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inSampleSize = sample;
        Bitmap bitmap = BitmapFactory.decodeByteArray(encoded, 0, encoded.length, options);
        if (bitmap == null) return null;
        try {
            BoundedOutput output = new BoundedOutput(MAX_PAYLOAD);
            return bitmap.compress(Bitmap.CompressFormat.PNG, 100, output) ? output.toByteArray() : null;
        } finally {
            bitmap.recycle();
        }
    }

    private static boolean plausible(int width, int height) {
        return width > 0 && height > 0 && width <= 16_384 && height <= 16_384
                && (long) width * height <= 100_000_000L;
    }

    private static byte[] readBounded(InputStream input, int limit) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream(Math.min(limit, 64 * 1024));
        byte[] buffer = new byte[16 * 1024];
        int total = 0;
        for (int count; (count = input.read(buffer)) >= 0;) {
            total += count;
            if (total > limit) throw new IOException("clipboard image exceeds source limit");
            output.write(buffer, 0, count);
        }
        return output.toByteArray();
    }

    private static final class Snapshot {
        final byte kind;
        final byte[] content;
        final byte[] digest;
        final long timestamp;
        final String origin;
        final String platformSource;
        Snapshot(byte kind, byte[] content, byte[] digest, long timestamp, String origin, String platformSource) {
            this.kind = kind;
            this.content = content;
            this.digest = digest;
            this.timestamp = timestamp;
            this.origin = origin;
            this.platformSource = platformSource;
        }
    }

    private static final class BoundedOutput extends OutputStream {
        private final int limit;
        private final ByteArrayOutputStream output = new ByteArrayOutputStream();
        BoundedOutput(int limit) { this.limit = limit; }
        @Override public void write(int value) throws IOException { ensure(1); output.write(value); }
        @Override public void write(byte[] bytes, int offset, int length) throws IOException {
            ensure(length); output.write(bytes, offset, length);
        }
        private void ensure(int additional) throws IOException {
            if ((long) output.size() + additional > limit) throw new IOException("clipboard image exceeds payload limit");
        }
        byte[] toByteArray() { return output.toByteArray(); }
    }
}
