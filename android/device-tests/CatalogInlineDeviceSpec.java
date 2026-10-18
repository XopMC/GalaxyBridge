package com.xopmc.galaxybridge.qa;
import android.graphics.Bitmap;
import android.util.Base64;
import java.io.ByteArrayOutputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;
import org.json.JSONArray;
import org.json.JSONObject;

/** Synthetic catalog only: no app enumeration, context, files, network or permissions. */
public final class CatalogInlineDeviceSpec {
    private static void require(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
    public static void main(String[] args) {
        try { run(); }
        catch (Throwable failure) {
            failure.printStackTrace(System.err);
            System.exit(1);
        }
    }
    private static void run() throws Exception {
        System.out.println("catalog_spec_pid=" + android.os.Process.myPid());
        Class<?> type = Class.forName("com.xopmc.galaxybridge.catalog.ApplicationCatalogExporter");
        Object exporter = type.getField("INSTANCE").get(null);
        Class<?> item = Class.forName("com.xopmc.galaxybridge.catalog.ApplicationCatalogExporter$Application");
        Constructor<?> constructor = item.getConstructor(String.class, String.class, String.class, boolean.class, byte[].class);
        Method encode = type.getDeclaredMethod("inlineJSON", List.class);
        Bitmap image = Bitmap.createBitmap(120, 120, Bitmap.Config.ARGB_8888);
        Random random = new Random(17);
        int[] pixels = new int[120 * 120];
        for (int i = 0; i < pixels.length; i++) pixels[i] = 0xff000000 | random.nextInt(0xffffff);
        image.setPixels(pixels, 0, 120, 0, 0, 120, 120);
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        require(image.compress(Bitmap.CompressFormat.PNG, 100, output), "PNG encoding failed");
        image.recycle();
        byte[] png = output.toByteArray();
        require(png.length <= 65536, "Synthetic icon exceeds producer limit");
        for (int count : new int[] {0, 1, 80, 512}) {
            System.out.println("catalog_spec_start count=" + count);
            List<Object> entries = new ArrayList<>();
            for (int i = 0; i < count; i++) {
                String pkg = "com.example.synthetic" + i;
                entries.add(constructor.newInstance(pkg, pkg + "/.Main", "Synthetic " + i, false, png));
            }
            byte[] payload = (byte[]) encode.invoke(exporter, entries);
            require(payload.length <= 2 * 1024 * 1024, "Wire bound exceeded");
            JSONObject root = new JSONObject(new String(payload, "UTF-8"));
            JSONArray rows = root.getJSONArray("applications");
            require(rows.length() == count, "App metadata was dropped");
            require(root.getInt("icons_omitted") == 0, "Synthetic valid icons were omitted");
            for (int i = 0; i < count; i++) {
                byte[] icon = Base64.decode(rows.getJSONObject(i).getString("icon_png_base64"), Base64.NO_WRAP);
                android.graphics.BitmapFactory.Options options = new android.graphics.BitmapFactory.Options();
                options.inJustDecodeBounds = true;
                android.graphics.BitmapFactory.decodeByteArray(icon, 0, icon.length, options);
                require(options.outWidth > 0 && options.outHeight > 0 && options.outWidth <= 128 && options.outHeight <= 128,
                    "Invalid icon dimensions");
                if (count == 1) require(java.util.Arrays.equals(icon, png), "Small catalog changed original icon");
            }
            System.out.println("PASS real Android JSON/PNG catalog count=" + count + " bytes=" + payload.length);
        }
    }
}
