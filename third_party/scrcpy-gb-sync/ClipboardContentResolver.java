package com.genymobile.scrcpy.wrappers;

import android.content.ContentResolver;
import android.content.Context;
import android.content.IContentProvider;
import android.os.Binder;

import java.util.ArrayDeque;
import java.util.IdentityHashMap;

/** Shell resolver with real unstable-provider acquisition and balanced external leases. */
public final class ClipboardContentResolver extends ContentResolver {
    private static final class Lease {
        final String authority;
        final Binder token = new Binder();
        Lease(String authority) { this.authority = authority; }
    }

    private final IdentityHashMap<IContentProvider, ArrayDeque<Lease>> leases = new IdentityHashMap<>();

    public ClipboardContentResolver(Context context) { super(context); }

    @SuppressWarnings("unused")
    protected synchronized IContentProvider acquireProvider(Context context, String authority) {
        Lease lease = new Lease(authority);
        IContentProvider provider = ServiceManager.getActivityManager().getContentProviderExternal(authority, lease.token);
        if (provider != null) leases.computeIfAbsent(provider, ignored -> new ArrayDeque<>()).addLast(lease);
        return provider;
    }

    @SuppressWarnings("unused")
    public synchronized boolean releaseProvider(IContentProvider provider) {
        ArrayDeque<Lease> references = leases.get(provider);
        if (references == null || references.isEmpty()) return false;
        Lease lease = references.removeLast();
        if (references.isEmpty()) leases.remove(provider);
        ServiceManager.getActivityManager().removeContentProviderExternal(lease.authority, lease.token);
        return true;
    }

    @SuppressWarnings("unused")
    protected IContentProvider acquireUnstableProvider(Context context, String authority) {
        return acquireProvider(context, authority);
    }

    @SuppressWarnings("unused")
    public boolean releaseUnstableProvider(IContentProvider provider) { return releaseProvider(provider); }

    @SuppressWarnings("unused")
    public void unstableProviderDied(IContentProvider provider) {
        // ContentResolver's finally block still owns and releases this lease.
    }
}
