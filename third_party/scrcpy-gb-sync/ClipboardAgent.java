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

import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.security.MessageDigest;
import java.util.Arrays;

/** Polls the complete Android primary clip from scrcpy's shell context. */
public final class ClipboardAgent {
    private static final byte KIND_TEXT = 1;
    private static final byte KIND_PNG = 3;
    private static final int MAX_PAYLOAD = 4 * 1024 * 1024;
    private static final int MAX_SOURCE = 16 * 1024 * 1024;
    private static final long POLL_MILLIS = 350;

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
        try (LocalServerSocket server = new LocalServerSocket(socketName);
             LocalSocket socket = server.accept();
             DataOutputStream output = new DataOutputStream(socket.getOutputStream())) {
            output.write(new byte[] {'G', 'B', 'C', '1'});
            output.flush();
            byte[] previousDigest = null;
            long previousTimestamp = Long.MIN_VALUE;
            while (!Thread.currentThread().isInterrupted()) {
                Snapshot snapshot = readSnapshot(clipboard);
                if (snapshot == null) {
                    previousDigest = null;
                    previousTimestamp = Long.MIN_VALUE;
                } else if (snapshot.timestamp != previousTimestamp || !Arrays.equals(snapshot.digest, previousDigest)) {
                    output.writeByte(snapshot.kind);
                    output.writeInt(snapshot.content.length);
                    output.write(snapshot.content);
                    output.flush();
                    previousDigest = snapshot.digest;
                    previousTimestamp = snapshot.timestamp;
                }
                Thread.sleep(POLL_MILLIS);
            }
        }
    }

    private static Snapshot readSnapshot(ClipboardManager clipboard) {
        try {
            ClipDescription description = clipboard.getPrimaryClipDescription();
            if (description == null || isSensitive(description)) return null;
            ClipData clip = clipboard.getPrimaryClip();
            if (clip == null || clip.getItemCount() == 0) return null;
            ClipData.Item item = clip.getItemAt(0);
            byte kind;
            byte[] content;
            if (description.hasMimeType("image/*") && item.getUri() != null) {
                content = readImage(FakeContext.get().getContentResolver(), item.getUri());
                kind = KIND_PNG;
            } else if (item.getText() != null) {
                content = item.getText().toString().getBytes(java.nio.charset.StandardCharsets.UTF_8);
                kind = KIND_TEXT;
            } else {
                return null;
            }
            if (content == null || content.length == 0 || content.length > MAX_PAYLOAD) return null;
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            digest.update(kind);
            digest.update(content);
            return new Snapshot(kind, content, digest.digest(), description.getTimestamp());
        } catch (RuntimeException error) {
            return null;
        } catch (Exception error) {
            return null;
        }
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
        Snapshot(byte kind, byte[] content, byte[] digest, long timestamp) {
            this.kind = kind;
            this.content = content;
            this.digest = digest;
            this.timestamp = timestamp;
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
