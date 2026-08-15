package io.github.ckarefulon.netaccelerator;

import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;

final class DnsPacketHandler {
    static byte[] handle(byte[] packet, int length, Map<String, List<byte[]>> rules,
                         AcceleratorVpnService.DnsForwarder forwarder) {
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
            List<byte[]> configured = rules.get(question.name);
            if (configured != null && question.type == 1) {
                List<byte[]> candidates = new ArrayList<>(configured);
                try {
                    for (byte[] address : extractA(forwarder.forward(query))) {
                        if (!contains(candidates, address) && candidates.size() < 8) candidates.add(address);
                    }
                } catch (Exception ignored) { }
                dnsResponse = answerA(query, question.endOffset, candidates);
            }
            else if (configured != null && question.type == 28) dnsResponse = answerEmpty(query, question.endOffset);
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

    private static byte[] answerA(byte[] query, int questionEnd, List<byte[]> addresses) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream(questionEnd + addresses.size() * 16);
        out.write(query, 0, questionEnd);
        byte[] data = out.toByteArray();
        data[2] = (byte) 0x81; data[3] = (byte) 0x80;
        data[6] = (byte) (addresses.size() >>> 8); data[7] = (byte) addresses.size();
        out.reset(); out.write(data);
        for (byte[] address : addresses) {
            out.write(new byte[] {(byte) 0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4});
            out.write(address);
        }
        return out.toByteArray();
    }

    private static List<byte[]> extractA(byte[] dns) {
        List<byte[]> result = new ArrayList<>();
        if (dns == null || dns.length < 12) return result;
        int offset = 12;
        int questions = u16(dns, 4), answers = u16(dns, 6);
        try {
            for (int i = 0; i < questions; i++) { offset = skipName(dns, offset); offset += 4; }
            for (int i = 0; i < answers && offset < dns.length; i++) {
                offset = skipName(dns, offset);
                if (offset + 10 > dns.length) break;
                int type = u16(dns, offset), klass = u16(dns, offset + 2), size = u16(dns, offset + 8);
                offset += 10;
                if (offset + size > dns.length) break;
                if (type == 1 && klass == 1 && size == 4) {
                    byte[] address = slice(dns, offset, 4);
                    if (!contains(result, address)) result.add(address);
                }
                offset += size;
            }
        } catch (Exception ignored) { }
        return result;
    }

    private static int skipName(byte[] dns, int offset) {
        while (offset < dns.length) {
            int size = dns[offset++] & 0xff;
            if (size == 0) return offset;
            if ((size & 0xc0) == 0xc0) {
                if (offset >= dns.length) throw new IllegalArgumentException("Truncated DNS pointer");
                return offset + 1;
            }
            if (size > 63 || offset + size > dns.length) throw new IllegalArgumentException("Invalid DNS name");
            offset += size;
        }
        throw new IllegalArgumentException("Truncated DNS name");
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

    private static boolean contains(List<byte[]> values, byte[] candidate) {
        for (byte[] value : values) if (Arrays.equals(value, candidate)) return true;
        return false;
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
