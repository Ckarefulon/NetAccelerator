package io.github.ckarefulon.netaccelerator;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Intent;
import android.net.VpnService;
import android.os.ParcelFileDescriptor;
import android.util.Log;

import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.util.concurrent.atomic.AtomicBoolean;

public final class AcceleratorVpnService extends VpnService {
    public static final String ACTION_START = "io.github.ckarefulon.netaccelerator.START";
    public static final String ACTION_STOP = "io.github.ckarefulon.netaccelerator.STOP";
    public static final String ACTION_STATE = "io.github.ckarefulon.netaccelerator.STATE";
    private static final String CHANNEL_ID = "accelerator";
    private static final int NOTIFICATION_ID = 7;
    private static final AtomicBoolean RUNNING = new AtomicBoolean(false);

    private ParcelFileDescriptor tunnel;
    private Thread worker;

    public static boolean isRunning() { return RUNNING.get(); }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_STOP.equals(intent.getAction())) {
            stopVpn();
            return START_NOT_STICKY;
        }
        startForeground(NOTIFICATION_ID, createNotification());
        if (!RUNNING.get()) startVpn();
        return START_STICKY;
    }

    @Override public void onRevoke() { stopVpn(); }
    @Override public void onDestroy() { stopVpn(); super.onDestroy(); }

    private synchronized void startVpn() {
        try {
            tunnel = new Builder()
                    .setSession("NetAccelerator")
                    .setMtu(1500)
                    .addAddress("10.77.0.2", 32)
                    .addDnsServer("10.77.0.1")
                    .addRoute("10.77.0.1", 32)
                    .setBlocking(true)
                    .establish();
            if (tunnel == null) throw new IllegalStateException("VPN permission is unavailable");
            RUNNING.set(true);
            worker = new Thread(this::runDnsLoop, "NetAccelerator-DNS");
            worker.start();
            sendBroadcast(new Intent(ACTION_STATE).setPackage(getPackageName()));
        } catch (Exception error) {
            Log.e("NetAccelerator", "Could not start VPN", error);
            stopVpn();
        }
    }

    private void runDnsLoop() {
        try (FileInputStream input = new FileInputStream(tunnel.getFileDescriptor());
             FileOutputStream output = new FileOutputStream(tunnel.getFileDescriptor())) {
            byte[] packet = new byte[32767];
            while (RUNNING.get()) {
                int length = input.read(packet);
                if (length <= 0) continue;
                byte[] response = DnsPacketHandler.handle(packet, length, this::forwardDns);
                if (response != null) output.write(response);
            }
        } catch (Exception error) {
            if (RUNNING.get()) Log.e("NetAccelerator", "DNS loop stopped", error);
        } finally {
            if (RUNNING.get()) stopVpn();
        }
    }

    private byte[] forwardDns(byte[] query) throws Exception {
        InetAddress resolver = InetAddress.getByName("1.1.1.1");
        try (DatagramSocket socket = new DatagramSocket()) {
            if (!protect(socket)) throw new IllegalStateException("Could not exclude DNS socket from VPN");
            socket.setSoTimeout(3500);
            socket.send(new DatagramPacket(query, query.length, resolver, 53));
            byte[] buffer = new byte[4096];
            DatagramPacket reply = new DatagramPacket(buffer, buffer.length);
            socket.receive(reply);
            byte[] result = new byte[reply.getLength()];
            System.arraycopy(reply.getData(), reply.getOffset(), result, 0, result.length);
            return result;
        }
    }

    private synchronized void stopVpn() {
        if (!RUNNING.getAndSet(false) && tunnel == null) { stopSelf(); return; }
        try { if (tunnel != null) tunnel.close(); } catch (Exception ignored) { }
        tunnel = null;
        if (worker != null && worker != Thread.currentThread()) worker.interrupt();
        worker = null;
        sendBroadcast(new Intent(ACTION_STATE).setPackage(getPackageName()));
        stopForeground(STOP_FOREGROUND_REMOVE);
        stopSelf();
    }

    private Notification createNotification() {
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel(CHANNEL_ID, "加速状态", NotificationManager.IMPORTANCE_LOW));
        Intent open = new Intent(this, MainActivity.class);
        PendingIntent pending = PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle("NetAccelerator 正在运行")
                .setContentText("GitHub DNS 路由已启用")
                .setContentIntent(pending)
                .setOngoing(true)
                .build();
    }

    interface DnsForwarder { byte[] forward(byte[] query) throws Exception; }
}
