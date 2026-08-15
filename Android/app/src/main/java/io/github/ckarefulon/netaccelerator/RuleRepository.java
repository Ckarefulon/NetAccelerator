package io.github.ckarefulon.netaccelerator;

import android.content.Context;
import android.net.Network;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

final class RuleRepository {
    private static final String ASSET_NAME = "android-rules.json";
    private static final String CACHE_NAME = "android-rules-cache.json";
    private static final String UPDATE_URL =
            "https://raw.githubusercontent.com/Ckarefulon/NetAccelerator/main/Android/app/src/main/assets/android-rules.json";
    private static final int MAX_RULE_BYTES = 256 * 1024;

    static Snapshot load(Context context) {
        File cache = new File(context.getFilesDir(), CACHE_NAME);
        if (cache.isFile()) {
            try (InputStream input = new FileInputStream(cache)) {
                return parse(readLimited(input), "本地更新缓存");
            } catch (Exception ignored) { }
        }
        try (InputStream input = context.getAssets().open(ASSET_NAME)) {
            return parse(readLimited(input), "应用内置规则");
        } catch (Exception error) {
            throw new IllegalStateException("无法读取内置规则", error);
        }
    }

    static Snapshot refresh(Context context, Network network) throws Exception {
        if (network == null) throw new IllegalStateException("没有可用的底层网络");
        HttpURLConnection connection = (HttpURLConnection) network.openConnection(new URL(UPDATE_URL));
        connection.setConnectTimeout(3500);
        connection.setReadTimeout(4500);
        connection.setUseCaches(false);
        connection.setRequestProperty("Accept", "application/json");
        connection.setRequestProperty("User-Agent", "NetAccelerator-Android/0.2");
        try {
            if (connection.getResponseCode() != 200)
                throw new IllegalStateException("规则服务器返回 HTTP " + connection.getResponseCode());
            byte[] content;
            try (InputStream input = connection.getInputStream()) { content = readLimited(input); }
            Snapshot snapshot = parse(content, "远程更新 " + new JSONObject(new String(content, StandardCharsets.UTF_8)).optString("updated", ""));
            writeAtomically(context, content);
            return snapshot;
        } finally {
            connection.disconnect();
        }
    }

    private static Snapshot parse(byte[] content, String description) throws Exception {
        JSONObject root = new JSONObject(new String(content, StandardCharsets.UTF_8));
        if (root.optInt("schema", -1) != 1) throw new IllegalArgumentException("不支持的规则版本");
        JSONObject rulesObject = root.getJSONObject("rules");
        Map<String, List<byte[]>> rules = new HashMap<>();
        JSONArray names = rulesObject.names();
        if (names == null) throw new IllegalArgumentException("规则为空");
        for (int i = 0; i < names.length(); i++) {
            String host = names.getString(i).trim().toLowerCase();
            if (!host.matches("[a-z0-9.-]+") || host.startsWith(".") || host.endsWith("."))
                throw new IllegalArgumentException("非法域名：" + host);
            JSONArray candidates = rulesObject.getJSONArray(host);
            List<byte[]> addresses = new ArrayList<>();
            for (int j = 0; j < candidates.length() && addresses.size() < 8; j++) {
                byte[] address = parseIpv4(candidates.getString(j));
                if (!contains(addresses, address)) addresses.add(address);
            }
            if (!addresses.isEmpty()) rules.put(host, Collections.unmodifiableList(addresses));
        }
        if (rules.isEmpty()) throw new IllegalArgumentException("没有有效规则");
        return new Snapshot(Collections.unmodifiableMap(rules), description.trim());
    }

    private static void writeAtomically(Context context, byte[] content) throws Exception {
        File target = new File(context.getFilesDir(), CACHE_NAME);
        File temporary = new File(context.getFilesDir(), CACHE_NAME + ".tmp");
        try (FileOutputStream output = new FileOutputStream(temporary)) {
            output.write(content);
            output.getFD().sync();
        }
        try {
            Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        } catch (AtomicMoveNotSupportedException ignored) {
            Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING);
        }
    }

    private static byte[] readLimited(InputStream input) throws Exception {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] buffer = new byte[8192];
        int count;
        while ((count = input.read(buffer)) >= 0) {
            if (output.size() + count > MAX_RULE_BYTES) throw new IllegalArgumentException("规则文件过大");
            output.write(buffer, 0, count);
        }
        return output.toByteArray();
    }

    private static boolean contains(List<byte[]> values, byte[] candidate) {
        for (byte[] value : values) {
            if (java.util.Arrays.equals(value, candidate)) return true;
        }
        return false;
    }

    private static byte[] parseIpv4(String value) {
        String[] fields = value.split("\\.", -1);
        if (fields.length != 4) throw new IllegalArgumentException("只允许 IPv4 字面量：" + value);
        byte[] result = new byte[4];
        for (int i = 0; i < fields.length; i++) {
            if (fields[i].isEmpty() || (fields[i].length() > 1 && fields[i].startsWith("0")))
                throw new IllegalArgumentException("IPv4 格式无效：" + value);
            int number;
            try { number = Integer.parseInt(fields[i]); }
            catch (NumberFormatException error) { throw new IllegalArgumentException("IPv4 格式无效：" + value); }
            if (number < 0 || number > 255) throw new IllegalArgumentException("IPv4 格式无效：" + value);
            result[i] = (byte) number;
        }
        return result;
    }

    static final class Snapshot {
        final Map<String, List<byte[]>> rules;
        final String description;
        Snapshot(Map<String, List<byte[]>> rules, String description) {
            this.rules = rules;
            this.description = description;
        }
    }
}
