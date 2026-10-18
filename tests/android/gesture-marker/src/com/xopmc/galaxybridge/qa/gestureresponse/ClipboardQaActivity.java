package com.xopmc.galaxybridge.qa.gestureresponse;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.net.Uri;
import android.os.Bundle;
import android.widget.Button;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.security.MessageDigest;
import java.util.UUID;
import org.json.JSONObject;

/** Foreground-only neutral copy/paste acceptance. No permissions or launcher. */
public final class ClipboardQaActivity extends Activity {
    private static final int WIDTH = 512, HEIGHT = 320, MAX_BYTES = 16 * 1024 * 1024;
    private TextView status;
    private ImageView preview;
    private String run, requested;
    private boolean performed;

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        run = getIntent().getStringExtra("qa_run");
        try {
            if (run == null || !UUID.fromString(run).toString().equals(run)) { finish(); return; }
        } catch (IllegalArgumentException error) { finish(); return; }
        requested = getIntent().getStringExtra("qa_operation");
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL); root.setPadding(24, 24, 24, 24);
        root.setOnApplyWindowInsetsListener(new android.view.View.OnApplyWindowInsetsListener() {
            @Override public android.view.WindowInsets onApplyWindowInsets(android.view.View view, android.view.WindowInsets insets) {
                android.graphics.Insets bars = insets.getInsets(android.view.WindowInsets.Type.systemBars());
                view.setPadding(24 + bars.left, 24 + bars.top, 24 + bars.right, 24 + bars.bottom);
                return insets;
            }
        });
        status = new TextView(this); status.setTextSize(20);
        status.setText("Clipboard acceptance\nOnly generated text and images."); root.addView(status);
        for (String op : new String[]{"copy-text", "paste-text", "copy-image", "paste-image"}) {
            Button button = new Button(this); button.setText(op);
            button.setOnClickListener(new android.view.View.OnClickListener() {
                @Override public void onClick(android.view.View view) { perform(op); }
            }); root.addView(button);
        }
        preview = new ImageView(this); preview.setScaleType(ImageView.ScaleType.FIT_CENTER);
        root.addView(preview, new LinearLayout.LayoutParams(-1, 0, 1)); setContentView(root);
    }

    @Override public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        if (focused && !performed && requested != null) {
            performed = true;
            getWindow().getDecorView().post(new Runnable() {
                @Override public void run() { perform(requested); }
            });
        }
    }

    private static Bitmap vector(int variant) {
        int[] pixels = new int[WIDTH * HEIGHT];
        int[] colors = variant == 0 ? new int[]{0xff204070, 0xfff3b542, 0xffeff3fa}
            : new int[]{0xff6753c8, 0xff1d9b86, 0xffffcb80};
        for (int y = 0; y < HEIGHT; y++) for (int x = 0; x < WIDTH; x++)
            pixels[y * WIDTH + x] = colors[x < WIDTH / 3 ? 0 : y < HEIGHT / 2 ? 1 : 2];
        return Bitmap.createBitmap(pixels, WIDTH, HEIGHT, Bitmap.Config.ARGB_8888);
    }

    private static String digest(byte[] value) throws Exception {
        StringBuilder text = new StringBuilder();
        for (byte b : MessageDigest.getInstance("SHA-256").digest(value)) text.append(String.format("%02x", b & 255));
        return text.toString();
    }

    private static byte[] rgba(Bitmap bitmap) {
        int[] pixels = new int[bitmap.getWidth() * bitmap.getHeight()];
        bitmap.getPixels(pixels, 0, bitmap.getWidth(), 0, 0, bitmap.getWidth(), bitmap.getHeight());
        ByteBuffer out = ByteBuffer.allocate(pixels.length * 4);
        for (int pixel : pixels) out.put((byte)(pixel >> 16)).put((byte)(pixel >> 8)).put((byte)pixel).put((byte)(pixel >> 24));
        return out.array();
    }

    private void perform(String operation) {
        try {
            ClipboardManager clipboard = getSystemService(ClipboardManager.class);
            JSONObject receipt = new JSONObject().put("run", run).put("operation", operation);
            String expected = "GB-QA-MAC-" + run;
            if (operation.equals("copy-text")) {
                clipboard.setPrimaryClip(ClipData.newPlainText("Neutral QA", "GB-QA-PHONE-" + run));
                receipt.put("matched", true);
            } else if (operation.equals("paste-text")) {
                ClipData clip = clipboard.getPrimaryClip();
                CharSequence text = clip != null && clip.getItemCount() == 1 ? clip.getItemAt(0).getText() : null;
                receipt.put("matched", expected.contentEquals(text == null ? "" : text));
            } else if (operation.equals("copy-image")) {
                Bitmap bitmap = vector(1);
                File directory = new File(getCacheDir(), "clipboard-qa");
                if (!directory.isDirectory() && !directory.mkdirs()) throw new IllegalStateException();
                File file = new File(directory, "neutral.png");
                try (java.io.OutputStream out = new java.io.FileOutputStream(file)) {
                    if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)) throw new IllegalStateException();
                }
                Uri uri = Uri.parse("content://" + getPackageName() + ".clipboardqa/neutral.png");
                clipboard.setPrimaryClip(ClipData.newUri(getContentResolver(), "Neutral QA image", uri));
                preview.setImageBitmap(bitmap);
                receipt.put("matched", true).put("rgba_sha256", digest(rgba(bitmap)));
            } else if (operation.equals("paste-image")) {
                ClipData clip = clipboard.getPrimaryClip();
                Uri uri = clip != null && clip.getItemCount() == 1 ? clip.getItemAt(0).getUri() : null;
                if (uri == null) throw new IllegalArgumentException();
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                try (InputStream in = getContentResolver().openInputStream(uri)) {
                    if (in == null) throw new IllegalArgumentException();
                    byte[] buffer = new byte[8192]; int count;
                    while ((count = in.read(buffer)) >= 0) {
                        if (out.size() + count > MAX_BYTES) throw new IllegalArgumentException();
                        out.write(buffer, 0, count);
                    }
                }
                byte[] encoded = out.toByteArray();
                BitmapFactory.Options bounds = new BitmapFactory.Options(); bounds.inJustDecodeBounds = true;
                BitmapFactory.decodeByteArray(encoded, 0, encoded.length, bounds);
                if (bounds.outWidth != WIDTH || bounds.outHeight != HEIGHT) throw new IllegalArgumentException();
                Bitmap bitmap = BitmapFactory.decodeByteArray(encoded, 0, encoded.length);
                if (bitmap == null) throw new IllegalArgumentException();
                String pixels = digest(rgba(bitmap));
                boolean matches = pixels.equals(digest(rgba(vector(0))));
                receipt.put("matched", matches);
                if (matches) { receipt.put("rgba_sha256", pixels); preview.setImageBitmap(bitmap); }
            } else throw new IllegalArgumentException();
            receipt.put("success", true);
            try (java.io.OutputStream out = openFileOutput("clipboard-qa.json", MODE_PRIVATE)) {
                out.write(receipt.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));
            }
            status.setText(operation + "\n" + (receipt.optBoolean("matched") ? "Verified neutral content" : "Unexpected clipboard content"));
        } catch (Exception error) {
            // Never retain or display unrelated clipboard content, URI or exception text.
            status.setText("Clipboard acceptance failed");
            try (java.io.OutputStream out = openFileOutput("clipboard-qa.json", MODE_PRIVATE)) {
                out.write(new JSONObject().put("run", run).put("operation", operation).put("success", false)
                    .toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));
            } catch (Exception ignored) { }
        }
    }
}
