package com.genymobile.scrcpy;
import java.io.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Runs the production entrypoint/lifetime with a queued framework Handler boundary. */
public final class ClipboardCallbackLifecycleSpec {
    static final class Snapshot {}
    static volatile boolean denyListener;
    static int runs,added,removed;
    static final class Looper {
        static final ThreadLocal<Looper> local=new ThreadLocal<>();
        final BlockingQueue<Runnable> queue=new LinkedBlockingQueue<>();volatile boolean quit;
        static void prepare(){local.set(new Looper());}
        static Looper myLooper(){return local.get();}
        static void loop() throws InterruptedException {Looper l=myLooper();while(!l.quit)l.queue.take().run();}
        void quitSafely(){quit=true;queue.add(()->{});}
    }
    static final class Workarounds {static void apply(){}}
    static final class ClipboardManager {
        interface OnPrimaryClipChangedListener {void onPrimaryClipChanged();}
        final Looper handler=Looper.myLooper();OnPrimaryClipChangedListener listener;
        void addPrimaryClipChangedListener(OnPrimaryClipChangedListener l){
            if(denyListener)throw new IllegalStateException("unsupported listener");
            added++;listener=l;
        }
        void removePrimaryClipChangedListener(OnPrimaryClipChangedListener l){
            if(listener!=l)throw new AssertionError("wrong listener cleanup");removed++;listener=null;
        }
        void changed(){handler.queue.add(()->listener.onPrimaryClipChanged());}
    }
    static final class FakeContext {
        static final String CLIPBOARD_SERVICE="clipboard";
        static FakeContext get(){return new FakeContext();}
        Object getSystemService(String name){return new ClipboardManager();}
    }
    // ACTUAL_ENTRYPOINT_AND_CALLBACK_LIFETIME
    private static void run(String name,ClipboardManager clipboard,ClipboardSnapshotCache<Snapshot> cache)throws Exception{
        if(!name.equals("test.socket"))throw new AssertionError();runs++;
        Snapshot old=new Snapshot(),current=new Snapshot();
        cache.read(100,"text/plain",()->old);
        if(!denyListener){
            clipboard.changed();
            long limit=System.nanoTime()+TimeUnit.SECONDS.toNanos(2);
            while(cache.read(100,"text/plain",()->current)!=current){
                if(System.nanoTime()>limit)throw new AssertionError("callback Handler was never serviced");
                Thread.sleep(5);
            }
        }
        if(Looper.myLooper()!=null)throw new AssertionError("socket polling blocked callback Looper thread");
    }
    public static void test() throws Exception {
        main(new String[]{"test.socket"});
        if(runs!=1||added!=1||removed!=1)throw new AssertionError("callback lifetime did not clean up");
        denyListener=true;main(new String[]{"test.socket"});
        if(runs!=2||added!=1||removed!=1)throw new AssertionError("unsupported listener disabled polling fallback");
        System.out.println("PASS actual clipboard callback lifetime: serviced Looper, separate polling thread, listener cleanup and unsupported-listener fallback");
    }
}
