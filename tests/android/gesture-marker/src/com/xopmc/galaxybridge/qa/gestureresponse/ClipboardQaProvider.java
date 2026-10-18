package com.xopmc.galaxybridge.qa.gestureresponse;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.File;
import java.io.FileNotFoundException;

/** Serves exactly the generated QA image through Android's normal URI grants. */
public final class ClipboardQaProvider extends ContentProvider {
    @Override public boolean onCreate() { return true; }
    private File selected(Uri uri) throws FileNotFoundException {
        if (!uri.toString().equals("content://" + getContext().getPackageName() + ".clipboardqa/neutral.png"))
            throw new FileNotFoundException();
        return new File(getContext().getCacheDir(), "clipboard-qa/neutral.png");
    }
    @Override public String getType(Uri uri) {
        try { selected(uri); return "image/png"; } catch (FileNotFoundException error) { return null; }
    }
    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (!"r".equals(mode)) throw new FileNotFoundException();
        return ParcelFileDescriptor.open(selected(uri), ParcelFileDescriptor.MODE_READ_ONLY);
    }
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] arguments, String order) {
        try {
            File file = selected(uri);
            MatrixCursor cursor = new MatrixCursor(new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE});
            cursor.addRow(new Object[]{"neutral.png", file.length()}); return cursor;
        } catch (FileNotFoundException error) { return null; }
    }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String where, String[] args) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String where, String[] args) { throw new UnsupportedOperationException(); }
}
