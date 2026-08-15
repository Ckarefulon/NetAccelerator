package io.github.ckarefulon.netaccelerator;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Intent;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.VpnService;
import android.os.ParcelFileDescriptor;
import android.util.Log;

import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

public final class AcceleratorVpnService extends VpnService {
    public static final String ACTION_START = "io.github.ckarefulon.netaccelerator.START";
    public static final String ACTION_STOP = "io.github.ckarefulon.netaccelerator.STOP";
    public static final String ACTION_STATE = "io.github.ckarefulon.netaccelerator.STATE";
    private static final String CHANNEL_ID = "accelerator";
    private static final int NOTIFICATION_ID = 7;
    private static final AtomicBoolean RUNNING = new AtomicBoolean(false);
    private static volatile String RULE_STATUS = "尚未加载规则";

    private ParcelFileDescriptor tunnel;
    private Thread worker;
    private ScheduledExecutorService updater;
    private volatile RuleRepository.Snapshot ruleSnapshot;
    private DnsResolverChain resolverChain;

    public static boolean isRunning() { return RUNNING.get(); }
    public static String ruleStatus() { return RULE_STATUS; }

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
            ruleSnapshot = RuleRepository.load(this);
            RULE_STATUS = ruleSnapshot.description + " · " + ruleSnapshot.rules.size() + " 个域名";
            resolverChain = new DnsResolverChain(this);
            Network underlying = findUnderlyingNetwork();
            Builder builder = new Builder()
                    .setSession("NetAccelerator")
                    .setMtu(1500)
                    .addAddress("10.77.0.2", 32)
                    .addDnsServer("10.77.0.1")
                    .addRoute("10.77.0.1", 32)
                    .setBlocking(true);
            if (underlying != null) builder.setUnderlyingNetworks(new Network[] { underlying });
            tunnel = builder.establish();
            if (tunnel == null) throw new IllegalStateException("VPN permission is unavailable");
            RUNNING.set(true);
            worker = new Thread(this::runDnsLoop, "NetAccelerator-DNS");
            worker.start();
            updater = Executors.newSingleThreadScheduledExecutor(r -> {
                Thread thread = new Thread(r, "NetAccelerator-Rules");
                thread.setDaemon(true);
                return thread;
            });
            updater.scheduleWithFixedDelay(this::refreshRules, 0, 6, TimeUnit.HOURS);
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
                RuleRepository.Snapshot current = ruleSnapshot;
                byte[] response = DnsPacketHandler.handle(packet, length, current.rules, resolverChain::resolve);
                if (response != null) output.write(response);
            }
        } catch (Exception error) {
            if (RUNNING.get()) Log.e("NetAccelerator", "DNS loop stopped", error);
        } finally {
            if (RUNNING.get()) stopVpn();
        }
    }

    private void refreshRules() {
        try {
            RuleRepository.Snapshot updated = RuleRepository.refresh(this, findUnderlyingNetwork());
            ruleSnapshot = updated;
            RULE_STATUS = updated.description + " · " + updated.rules.size() + " 个域名";
        } catch (Exception error) {
            RuleRepository.Snapshot current = ruleSnapshot;
            RULE_STATUS = (current == null ? "规则更新失败" : current.description + "（更新失败，继续使用）");
            Log.w("NetAccelerator", "Rule refresh failed", error);
        }
        sendBroadcast(new Intent(ACTION_STATE).setPackage(getPackageName()));
    }

    Network findUnderlyingNetwork() {
        ConnectivityManager manager = getSystemService(ConnectivityManager.class);
        Network fallback = null;
        for (Network network : manager.getAllNetworks()) {
            NetworkCapabilities capabilities = manager.getNetworkCapabilities(network);
            if (capabilities == null || capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
                    || !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue;
            if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) return network;
            if (fallback == null) fallback = network;
        }
        return fallback;
    }

    private synchronized void stopVpn() {
        if (!RUNNING.getAndSet(false) && tunnel == null) { stopSelf(); return; }
        try { if (tunnel != null) tunnel.close(); } catch (Exception ignored) { }
        tunnel = null;
        if (updater != null) updater.shutdownNow();
        updater = null;
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
