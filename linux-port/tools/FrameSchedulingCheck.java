import android.os.Handler;
import android.os.Looper;
import android.view.Choreographer;
import java.lang.reflect.Method;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/** Checks that suspending frames preserves callbacks and leaves handlers live. */
public class FrameSchedulingCheck {
    public static void main(String[] args) throws Exception {
        CountDownLatch done = new CountDownLatch(1);
        AtomicReference<Throwable> failure = new AtomicReference<>();
        Thread worker = new Thread(() -> {
            try {
                Looper.prepare();
                Choreographer choreographer = Choreographer.getInstance();
                Method enable = Choreographer.class.getDeclaredMethod("setFramesEnabled", boolean.class);
                enable.setAccessible(true);
                Handler handler = new Handler();
                int[] calls = {0};
                choreographer.postFrameCallback(time -> calls[0]++);
                enable.invoke(choreographer, false);
                choreographer.postFrameCallbackDelayed(time -> calls[0]++, 30);
                handler.postDelayed(() -> {
                    try {
                        if (calls[0] != 0)
                            throw new AssertionError("frame ran while suspended");
                        enable.invoke(choreographer, true);
                        handler.postDelayed(() -> {
                            if (calls[0] != 2)
                                failure.set(new AssertionError("pending callbacks lost or repeated: " + calls[0]));
                            Looper.myLooper().quit();
                            done.countDown();
                        }, 100);
                    } catch (Throwable error) {
                        failure.set(error);
                        Looper.myLooper().quit();
                        done.countDown();
                    }
                }, 100);
                Looper.loop();
            } catch (Throwable error) {
                failure.set(error);
                done.countDown();
            }
        });
        worker.setDaemon(true);
        worker.start();
        if (!done.await(5, TimeUnit.SECONDS))
            throw new AssertionError("handlers stopped while frames were suspended");
        if (failure.get() != null)
            throw new AssertionError("frame scheduling failed", failure.get());
        System.out.println("PASS frame callbacks suspended and resumed; handlers stayed live");
        System.exit(0);
    }
}
