package io.github.ckarefulon.netaccelerator;

import android.net.Network;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.URL;

final class DnsResolverChain {
    private static final String[] DOH_ENDPOINTS = {
            "https://doh.pub/dns-query",
            "https://cloudflare-dns.com/dns-query"
    };
    private static final String[] UDP_FALLBACKS = { "119.29.29.29", "223.5.5.5" };
    private final AcceleratorVpnService service;

    DnsResolverChain(AcceleratorVpnService service) { this.service = service; }

    byte[] resolve(byte[] query) throws Exception {
        Exception last = null;
        Network network = service.findUnderlyingNetwork();
        if (network != null) {
            for (String endpoint : DOH_ENDPOINTS) {
                try { return queryDoh(network, endpoint, query); }
                catch (Exception error) { last = error; }
            }
        }
        for (String resolver : UDP_FALLBACKS) {
            try { return queryUdp(resolver, query); }
            catch (Exception error) { last = error; }
        }
        throw new IllegalStateException("所有 DNS 上游均不可用", last);
    }

    private byte[] queryDoh(Network network, String endpoint, byte[] query) throws Exception {
        HttpURLConnection connection = (HttpURLConnection) network.openConnection(new URL(endpoint));
        connection.setConnectTimeout(2200);
        connection.setReadTimeout(2800);
        connection.setRequestMethod("POST");
        connection.setDoOutput(true);
        connection.setUseCaches(false);
        connection.setFixedLengthStreamingMode(query.length);
        connection.setRequestProperty("Content-Type", "application/dns-message");
        connection.setRequestProperty("Accept", "application/dns-message");
        try {
            try (OutputStream output = connection.getOutputStream()) { output.write(query); }
            if (connection.getResponseCode() != 200)
                throw new IllegalStateException(endpoint + " 返回 HTTP " + connection.getResponseCode());
            try (InputStream input = connection.getInputStream()) { return validate(query, readDnsResponse(input)); }
        } finally {
            connection.disconnect();
        }
    }

    private byte[] queryUdp(String resolver, byte[] query) throws Exception {
        try (DatagramSocket socket = new DatagramSocket()) {
            if (!service.protect(socket)) throw new IllegalStateException("无法排除 DNS 套接字的 VPN 路由");
            socket.setSoTimeout(1600);
            InetAddress address = InetAddress.getByName(resolver);
            socket.send(new DatagramPacket(query, query.length, address, 53));
            byte[] buffer = new byte[4096];
            DatagramPacket reply = new DatagramPacket(buffer, buffer.length);
            socket.receive(reply);
            byte[] result = new byte[reply.getLength()];
            System.arraycopy(reply.getData(), reply.getOffset(), result, 0, result.length);
            return validate(query, result);
        }
    }

    private byte[] readDnsResponse(InputStream input) throws Exception {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] buffer = new byte[2048];
        int count;
        while ((count = input.read(buffer)) >= 0) {
            if (output.size() + count > 65535) throw new IllegalArgumentException("DNS 响应过大");
            output.write(buffer, 0, count);
        }
        if (output.size() < 12) throw new IllegalArgumentException("DNS 响应不完整");
        return output.toByteArray();
    }

    private byte[] validate(byte[] query, byte[] response) {
        if (query.length < 2 || response.length < 12 || response[0] != query[0] || response[1] != query[1]
                || (response[2] & 0x80) == 0)
            throw new IllegalArgumentException("DNS 响应校验失败");
        return response;
    }
}
