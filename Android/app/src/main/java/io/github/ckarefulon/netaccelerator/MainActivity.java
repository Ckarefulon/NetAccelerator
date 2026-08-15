package io.github.ckarefulon.netaccelerator;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Color;
import android.net.VpnService;
import android.os.Build;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

public final class MainActivity extends Activity {
    private static final int VPN_REQUEST = 1001;
    private TextView status;
    private TextView ruleStatus;
    private Button action;

    private final BroadcastReceiver stateReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) { render(); }
    };

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        setContentView(createContent());
        action.setOnClickListener(v -> {
            if (AcceleratorVpnService.isRunning()) {
                startService(new Intent(this, AcceleratorVpnService.class).setAction(AcceleratorVpnService.ACTION_STOP));
            } else {
                Intent permission = VpnService.prepare(this);
                if (permission == null) startAccelerator();
                else startActivityForResult(permission, VPN_REQUEST);
            }
        });
        render();
    }

    @Override protected void onStart() {
        super.onStart();
        IntentFilter filter = new IntentFilter(AcceleratorVpnService.ACTION_STATE);
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(stateReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
        else registerReceiver(stateReceiver, filter);
        render();
    }

    @Override protected void onStop() {
        unregisterReceiver(stateReceiver);
        super.onStop();
    }

    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == VPN_REQUEST && resultCode == RESULT_OK) startAccelerator();
    }

    private void startAccelerator() {
        Intent intent = new Intent(this, AcceleratorVpnService.class).setAction(AcceleratorVpnService.ACTION_START);
        startForegroundService(intent);
    }

    private void render() {
        boolean running = AcceleratorVpnService.isRunning();
        status.setText(running ? "加速中\nGitHub DNS 路由已启用" : "已停止\n网络设置保持原状");
        status.setTextColor(Color.parseColor(running ? "#15803D" : "#475569"));
        action.setText(running ? "停止并恢复网络" : "开启 GitHub 加速");
        ruleStatus.setText("规则：" + AcceleratorVpnService.ruleStatus());
    }

    private View createContent() {
        int pad = dp(24);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER_HORIZONTAL);
        root.setPadding(pad, dp(56), pad, pad);
        root.setBackgroundColor(Color.parseColor("#F8FAFC"));

        TextView title = new TextView(this);
        title.setText("NetAccelerator");
        title.setTextSize(30);
        title.setTextColor(Color.parseColor("#0F172A"));
        title.setGravity(Gravity.CENTER);
        root.addView(title, matchWrap());

        TextView subtitle = new TextView(this);
        subtitle.setText("安卓无 Root 版");
        subtitle.setTextSize(15);
        subtitle.setTextColor(Color.parseColor("#64748B"));
        subtitle.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams subtitleParams = matchWrap();
        subtitleParams.topMargin = dp(8);
        root.addView(subtitle, subtitleParams);

        status = new TextView(this);
        status.setTextSize(19);
        status.setGravity(Gravity.CENTER);
        status.setLineSpacing(0, 1.25f);
        LinearLayout.LayoutParams statusParams = matchWrap();
        statusParams.topMargin = dp(64);
        root.addView(status, statusParams);

        ruleStatus = new TextView(this);
        ruleStatus.setTextSize(13);
        ruleStatus.setTextColor(Color.parseColor("#64748B"));
        ruleStatus.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams ruleParams = matchWrap();
        ruleParams.topMargin = dp(16);
        root.addView(ruleStatus, ruleParams);

        action = new Button(this);
        action.setTextSize(17);
        action.setAllCaps(false);
        LinearLayout.LayoutParams buttonParams = new LinearLayout.LayoutParams(-1, dp(56));
        buttonParams.topMargin = dp(40);
        root.addView(action, buttonParams);

        TextView note = new TextView(this);
        note.setText("优先使用加密 DNS，并自动更新与缓存规则。\n仅接管 DNS，不上传网页流量，不修改系统 Hosts。\n同一时间不能与其他 VPN 共用。");
        note.setTextSize(14);
        note.setTextColor(Color.parseColor("#64748B"));
        note.setGravity(Gravity.CENTER);
        note.setLineSpacing(0, 1.25f);
        LinearLayout.LayoutParams noteParams = matchWrap();
        noteParams.topMargin = dp(28);
        root.addView(note, noteParams);
        return root;
    }

    private LinearLayout.LayoutParams matchWrap() { return new LinearLayout.LayoutParams(-1, -2); }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
}
