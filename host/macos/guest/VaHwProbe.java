/*
 * VirtualAndroid: guest-side probe for the hardware bridges (test tool).
 *
 *   su 1000 app_process -cp /data/local/tmp/va_hw_probe.jar / VaHwProbe <cmd> [seconds]
 *
 *   sensors N        listen to every sensor for N s; per sensor: events, last values
 *   location N       request GPS updates for N s; print each fix
 *   play N [hz]      play a sine tone (default 440 Hz) through AudioTrack for N s
 *   record N         record from the default microphone for N s; print level per second
 *
 * Runs as the system uid (1000) so it has the location and microphone
 * permissions without being an installed app. Build with
 * host/macos/build.sh guest (javac against android.jar, then d8).
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
import android.content.Context;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.media.MediaRecorder;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;

import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

public final class VaHwProbe {
    private static Context systemContext() throws Exception {
        Class<?> at = Class.forName("android.app.ActivityThread");
        Object thread = at.getMethod("systemMain").invoke(null);
        return (Context) at.getMethod("getSystemContext").invoke(thread);
    }

    /* The main looper cannot quit: run done after N s, then exit. */
    private static void loopFor(int seconds, Runnable done) {
        new Handler(Looper.myLooper()).postDelayed(() -> {
            done.run();
            System.exit(0);
        }, seconds * 1000L);
        Looper.loop();
    }

    private static String fmt(float[] v, int n) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < Math.min(n, v.length); i++) {
            sb.append(i == 0 ? "" : " ").append(String.format(Locale.ROOT, "%.3f", v[i]));
        }
        return sb.toString();
    }

    private static void sensors(Context ctx, int seconds) {
        SensorManager sm = ctx.getSystemService(SensorManager.class);
        Map<Sensor, int[]> counts = new HashMap<>();
        Map<Sensor, float[]> last = new HashMap<>();
        SensorEventListener l = new SensorEventListener() {
            @Override public void onSensorChanged(SensorEvent e) {
                counts.computeIfAbsent(e.sensor, k -> new int[1])[0]++;
                last.put(e.sensor, e.values.clone());
            }
            @Override public void onAccuracyChanged(Sensor s, int a) {}
        };
        List<Sensor> all = sm.getSensorList(Sensor.TYPE_ALL);
        for (Sensor s : all) {
            sm.registerListener(l, s, SensorManager.SENSOR_DELAY_GAME);
        }
        loopFor(seconds, () -> {
            sm.unregisterListener(l);
            for (Sensor s : all) {
                int[] c = counts.get(s);
                float[] v = last.get(s);
                System.out.println(String.format(Locale.ROOT, "%-48s events=%-4d last=[%s]",
                        s.getName(), c == null ? 0 : c[0], v == null ? "" : fmt(v, 4)));
            }
        });
    }

    private static void location(Context ctx, int seconds) {
        LocationManager lm = ctx.getSystemService(LocationManager.class);
        final int[] fixes = {0};
        LocationListener l = new LocationListener() {
            @Override public void onLocationChanged(Location loc) {
                fixes[0]++;
                System.out.println(String.format(Locale.ROOT,
                        "fix %d: %.6f,%.6f alt=%.1f acc=%.1f speed=%.2f time=%d",
                        fixes[0], loc.getLatitude(), loc.getLongitude(), loc.getAltitude(),
                        loc.getAccuracy(), loc.getSpeed(), loc.getTime()));
            }
            @Override public void onStatusChanged(String p, int s, Bundle b) {}
            @Override public void onProviderEnabled(String p) {}
            @Override public void onProviderDisabled(String p) {
                System.out.println("provider disabled: " + p);
            }
        };
        System.out.println("location enabled: " + lm.isLocationEnabled() + ", gps provider: "
                + lm.isProviderEnabled(LocationManager.GPS_PROVIDER));
        lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1000, 0, l, Looper.myLooper());
        loopFor(seconds, () -> {
            lm.removeUpdates(l);
            System.out.println("fixes: " + fixes[0]);
        });
    }

    private static void play(int seconds, int hz) {
        int rate = 48000;
        AudioTrack t = new AudioTrack.Builder()
                .setAudioAttributes(new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                .setAudioFormat(new AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(rate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build())
                .setTransferMode(AudioTrack.MODE_STREAM).build();
        short[] buf = new short[rate / 10 * 2];
        long n = 0;
        t.play();
        for (int i = 0; i < seconds * 10; i++) {
            for (int f = 0; f < buf.length / 2; f++, n++) {
                short v = (short) (Math.sin(2 * Math.PI * hz * n / rate) * 12000);
                buf[2 * f] = v;
                buf[2 * f + 1] = v;
            }
            t.write(buf, 0, buf.length);
        }
        t.stop();
        System.out.println("played " + seconds + " s of " + hz + " Hz, underruns="
                + t.getUnderrunCount() + " route=" + (t.getRoutedDevice() == null ? "none"
                : t.getRoutedDevice().getProductName() + "/" + t.getRoutedDevice().getType()));
        t.release();
    }

    private static void record(int seconds) {
        int rate = 48000;
        int min = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT);
        AudioRecord r = new AudioRecord(MediaRecorder.AudioSource.MIC, rate,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, Math.max(min, 9600) * 2);
        if (r.getState() != AudioRecord.STATE_INITIALIZED) {
            System.out.println("AudioRecord not initialized");
            return;
        }
        short[] buf = new short[rate];
        r.startRecording();
        for (int s = 0; s < seconds; s++) {
            int got = 0;
            while (got < buf.length) {
                int k = r.read(buf, got, buf.length - got);
                if (k <= 0) {
                    break;
                }
                got += k;
            }
            double sum = 0;
            int peak = 0;
            int crossings = 0;
            for (int i = 0; i < got; i++) {
                sum += (double) buf[i] * buf[i];
                peak = Math.max(peak, Math.abs(buf[i]));
                if (i > 0 && (buf[i - 1] < 0) != (buf[i] < 0)) {
                    crossings++;
                }
            }
            System.out.println(String.format(Locale.ROOT,
                    "second %d: %d frames rms=%.0f peak=%d ~%d Hz", s, got,
                    got > 0 ? Math.sqrt(sum / got) : 0, peak, crossings / 2));
        }
        r.stop();
        System.out.println("route=" + (r.getRoutedDevice() == null ? "none"
                : r.getRoutedDevice().getProductName() + "/" + r.getRoutedDevice().getType()));
        r.release();
    }

    public static void main(String[] args) throws Exception {
        if (args.length < 1) {
            System.err.println("usage: VaHwProbe sensors|location|play|record [seconds] [hz]");
            System.exit(2);
        }
        int seconds = args.length > 1 ? Integer.parseInt(args[1]) : 3;
        Looper.prepareMainLooper();
        Context ctx = systemContext();
        switch (args[0]) {
            case "sensors": sensors(ctx, seconds); break;
            case "location": location(ctx, seconds); break;
            case "play": play(seconds, args.length > 2 ? Integer.parseInt(args[2]) : 440); break;
            case "record": record(seconds); break;
            default: System.err.println("unknown command " + args[0]); System.exit(2);
        }
        System.exit(0);
    }
}
