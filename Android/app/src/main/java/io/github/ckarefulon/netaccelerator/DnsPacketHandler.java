package io.github.ckarefulon.netaccelerator;

import java.io.ByteArrayOutputStream;
import java.net.InetAddress;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;

final class DnsPacketHandler {
    private static final Map<String, byte[]> HOSTS;
    static {
        Map<String, byte[]> hosts = new HashMap<>();
        put(hosts, "github.dev", "20.43.185.14");
        put(hosts, "raw.github.com", "23.235.37.133");
        put(hosts, "githubusercontent.com", "23.235.37.133");
        put(hosts, "raw.githubusercontent.com", "23.235.37.133");
        put(hosts, "camo.githubusercontent.com", "23.235.37.133");
        put(hosts, "cloud.githubusercontent.com", "23.235.37.133");
        put(hosts, "avatars.githubusercontent.com", "23.235.37.133");
        put(hosts, "avatars0.githubusercontent.com", "23.235.37.133");
        put(hosts, "avatars1.githubusercontent.com", "23.235.37.133");
        put(hosts, "avatars2.githubusercontent.com", "23.235.37.133");
        put(hosts, "avatars3.githubusercontent.com", "23.235.37.133");
        put(hosts, "user-images.githubusercontent.com", "23.235.37.133");
        put(hosts, "objects.githubusercontent.com", "23.235.37.133");
        put(hosts, "private-user-images.githubusercontent.com", "23.235.37.133");
        put(hosts, "github.com", "20.207.73.82");
        put(hosts, "pages.github.com", "20.207.73.82");
        put(hosts, "gist.github.com", "20.207.73.82");
        put(hosts, "githubapp.com", "140.82.112.29");
        put(hosts, "hub.docker.com", "54.208.73.48");
        put(hosts, "github.io", "185.199.110.153");
        put(hosts, "www.github.io", "185.199.110.153");
        HOSTS = Collections.unmodifiableMap(hosts);
    }

    static byte[] handle(byte[] packet, int length, AcceleratorVpnService.DnsForwarder forwarder) {
        try {
            if (length < 28 || (packet[0] >>> 4) != 4) return null;
            int ipHeader = (packet[0] & 0x0f) * 4;
            if (ipHeader < 20 || length < ipHeader + 8 || (packet[9] & 0xff) != 17) return null;
            int sourcePort = u16(packet, ipHeader);
            int destinationPort = u16(packet, ipHeader + 2);
            if (destinationPort != 53) return null;
            int dnsOffset = ipHeader + 8;
            int dnsLength = Math.min(u16(packet, ipHeader + 4) - 8, length - dnsOffset);
            if (dnsLength < 17) return null;
            byte[] query = slice(packet, dnsOffset, dnsLength);
            Question question = parseQuestion(query);
            byte[] dnsResponse;
            byte[] address = HOSTS.get(question.name);
            if (address != null && question.type == 1) dnsResponse = answerA(query, question.endOffset, address);
            else if (address != null && question.type == 28) dnsResponse = answerEmpty(query, question.endOffset);
            else dnsResponse = forwarder.forward(query);
            return wrapUdpIpv4(packet, ipHeader, sourcePort, dnsResponse);
        } catch (Exception ignored) {
            return null;
        }
    }

    private static Question parseQuestion(byte[] dns) {
        if (u16(dns, 4) != 1) throw new IllegalArgumentException("Only one DNS question is supported");
        StringBuilder name = new StringBuilder();
        int offset = 12;
        while (offset < dns.length) {
            int size = dns[offset++] & 0xff;
            if (size == 0) break;
            if (size > 63 || offset + size > dns.length) throw new IllegalArgumentException("Invalid DNS name");
            if (name.length() > 0) name.append('.');
            for (int i = 0; i < size; i++) name.append((char) (dns[offset++] & 0xff));
        }
        if (offset + 4 > dns.length) throw new IllegalArgumentException("Truncated DNS question");
        int type = u16(dns, offset);
        return new Question(name.toString().toLowerCase(), type, offset + 4);
    }

    private static byte[] answerA(byte[] query, int questionEnd, byte[] address) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream(questionEnd + 16);
        out.write(query, 0, questionEnd);
        byte[] data = out.toByteArray();
        data[2] = (byte) 0x81; data[3] = (byte) 0x80;
        data[6] = 0; data[7] = 1;
        out.reset(); out.write(data);
        out.write(new byte[] {(byte) 0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4});
        out.write(address);
        return out.toByteArray();
    }

    private static byte[] answerEmpty(byte[] query, int questionEnd) {
        byte[] data = slice(query, 0, questionEnd);
        data[2] = (byte) 0x81; data[3] = (byte) 0x80;
        data[6] = 0; data[7] = 0;
        return data;
    }

    private static byte[] wrapUdpIpv4(byte[] request, int requestIpHeader, int clientPort, byte[] dns) {
        int total = 20 + 8 + dns.length;
        byte[] response = new byte[total];
        response[0] = 0x45;
        response[2] = (byte) (total >>> 8); response[3] = (byte) total;
        response[6] = 0x40;
        response[8] = 64; response[9] = 17;
        System.arraycopy(request, 16, response, 12, 4);
        System.arraycopy(request, 12, response, 16, 4);
        response[20] = 0; response[21] = 53;
        response[22] = (byte) (clientPort >>> 8); response[23] = (byte) clientPort;
        int udpLength = 8 + dns.length;
        response[24] = (byte) (udpLength >>> 8); response[25] = (byte) udpLength;
        System.arraycopy(dns, 0, response, 28, dns.length);
        int checksum = checksum(response, 0, 20);
        response[10] = (byte) (checksum >>> 8); response[11] = (byte) checksum;
        return response;
    }

    private static int checksum(byte[] data, int offset, int length) {
        long sum = 0;
        for (int i = offset; i < offset + length; i += 2)
            sum += ((data[i] & 0xff) << 8) | (i + 1 < offset + length ? data[i + 1] & 0xff : 0);
        while ((sum >>> 16) != 0) sum = (sum & 0xffff) + (sum >>> 16);
        return (int) (~sum) & 0xffff;
    }

    private static void put(Map<String, byte[]> map, String host, String ip) {
        try { map.put(host, InetAddress.getByName(ip).getAddress()); }
        catch (Exception error) { throw new IllegalArgumentException(error); }
    }

    private static int u16(byte[] data, int offset) { return ((data[offset] & 0xff) << 8) | (data[offset + 1] & 0xff); }
    private static byte[] slice(byte[] data, int offset, int length) {
        byte[] copy = new byte[length];
        System.arraycopy(data, offset, copy, 0, length);
        return copy;
    }

    private static final class Question {
        final String name; final int type; final int endOffset;
        Question(String name, int type, int endOffset) { this.name = name; this.type = type; this.endOffset = endOffset; }
    }
}
