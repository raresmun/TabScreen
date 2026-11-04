package local.tabscreen.viewer;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Socket;
import java.nio.charset.Charset;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;

/** A small WebSocket client for TabScreen's stream: one connection, whole (unsplit) messages. */
final class WebSocket {
    static final int TEXT = 0x1;
    static final int BINARY = 0x2;
    static final int CLOSE = 0x8;
    static final int PING = 0x9;
    static final int PONG = 0xA;

    private static final int MAX_MESSAGE = 32 * 1024 * 1024;
    private static final Charset UTF8 = Charset.forName("UTF-8");
    private static final Charset LATIN1 = Charset.forName("ISO-8859-1");
    private static final char[] BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toCharArray();

    /** The server answered with something other than "switching to WebSocket", e.g. 403 for a wrong key. */
    static final class RefusedException extends IOException {
        final int status;

        RefusedException(int status) {
            super("server answered " + status);
            this.status = status;
        }
    }

    private final Socket socket;
    private final InputStream in;
    private final OutputStream out;
    private final Object writeLock = new Object();
    private final SecureRandom random = new SecureRandom();
    private byte[] buffer = new byte[512 * 1024];
    private int length;
    private volatile long lastReceived = System.nanoTime();

    private WebSocket(Socket socket) throws IOException {
        this.socket = socket;
        this.in = new BufferedInputStream(socket.getInputStream(), 64 * 1024);
        this.out = socket.getOutputStream();
    }

    /** Upgrades an already connected socket to a WebSocket. */
    static WebSocket open(Socket socket, String hostHeader, String path, String userAgent) throws IOException {
        socket.setSoTimeout(5000);   // TabScreen answers right away; don't hang if something else is listening
        WebSocket webSocket = new WebSocket(socket);
        webSocket.handshake(hostHeader, path, userAgent);
        socket.setSoTimeout(0);
        webSocket.lastReceived = System.nanoTime();
        return webSocket;
    }

    private void handshake(String hostHeader, String path, String userAgent) throws IOException {
        byte[] nonce = new byte[16];
        random.nextBytes(nonce);
        String key = base64(nonce);
        String request = "GET " + path + " HTTP/1.1\r\n"
                + "Host: " + hostHeader + "\r\n"
                + "Upgrade: websocket\r\n"
                + "Connection: Upgrade\r\n"
                + "Sec-WebSocket-Key: " + key + "\r\n"
                + "Sec-WebSocket-Version: 13\r\n"
                + "User-Agent: " + userAgent + "\r\n"
                + "\r\n";
        synchronized (writeLock) {
            out.write(request.getBytes(UTF8));
            out.flush();
        }
        String[] lines = readHead().split("\r\n");
        int status = 0;
        String[] statusLine = lines[0].split(" ");
        if (statusLine.length >= 2 && statusLine[0].startsWith("HTTP/")) {
            try {
                status = Integer.parseInt(statusLine[1]);
            } catch (NumberFormatException ignored) {
                status = 0;
            }
        }
        if (status != 101) throw new RefusedException(status);
        String accept = null;
        for (int i = 1; i < lines.length; i++) {
            int colon = lines[i].indexOf(':');
            if (colon > 0 && lines[i].substring(0, colon).trim().equalsIgnoreCase("Sec-WebSocket-Accept")) {
                accept = lines[i].substring(colon + 1).trim();
            }
        }
        if (!base64(sha1(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")).equals(accept)) {
            throw new IOException("unexpected handshake answer");
        }
    }

    /** Reads the HTTP answer up to the empty line that ends it. */
    private String readHead() throws IOException {
        ByteArrayOutputStream head = new ByteArrayOutputStream(256);
        int matched = 0;   // how much of "\r\n\r\n" has been seen
        while (matched < 4) {
            int b = in.read();
            if (b < 0) throw new EOFException("connection closed during handshake");
            head.write(b);
            if (head.size() > 16384) throw new IOException("handshake answer too long");
            if (b == '\r') {
                matched = (matched == 2) ? 3 : 1;
            } else if (b == '\n' && (matched == 1 || matched == 3)) {
                matched++;
            } else {
                matched = 0;
            }
        }
        return new String(head.toByteArray(), LATIN1);
    }

    /**
     * Waits for the next text or binary message and returns its type ({@link #TEXT} or {@link #BINARY}),
     * or {@link #CLOSE} when the server ends the connection. The content is in {@link #data()},
     * {@link #length()} bytes long, until the next call. Pings are answered here.
     */
    int readMessage() throws IOException {
        while (true) {
            int first = readByte();
            int second = readByte();
            int opcode = first & 0x0F;
            boolean finished = (first & 0x80) != 0;
            long size = second & 0x7F;
            if (size == 126) {
                size = ((long) readByte() << 8) | readByte();
            } else if (size == 127) {
                size = 0;
                for (int i = 0; i < 8; i++) size = (size << 8) | readByte();
            }
            if (size < 0 || size > MAX_MESSAGE) throw new IOException("message too large: " + size);
            byte[] mask = null;
            if ((second & 0x80) != 0) {
                mask = new byte[4];
                readFully(mask, 4);
            }
            int count = (int) size;
            if (buffer.length < count) buffer = new byte[Math.max(count, buffer.length * 2)];
            readFully(buffer, count);
            if (mask != null) {
                for (int i = 0; i < count; i++) buffer[i] ^= mask[i & 3];
            }
            lastReceived = System.nanoTime();
            if (!finished || opcode == 0) throw new IOException("split messages are not supported");
            if (opcode == PING) {
                send(PONG, buffer, 0, count);
                continue;
            }
            if (opcode == PONG) continue;
            if (opcode == CLOSE) return CLOSE;
            if (opcode == TEXT || opcode == BINARY) {
                length = count;
                return opcode;
            }
            // Unknown message types are skipped.
        }
    }

    byte[] data() {
        return buffer;
    }

    int length() {
        return length;
    }

    long millisSinceLastMessage() {
        return (System.nanoTime() - lastReceived) / 1000000L;
    }

    void sendText(String text) throws IOException {
        byte[] bytes = text.getBytes(UTF8);
        send(TEXT, bytes, 0, bytes.length);
    }

    void sendPing() throws IOException {
        send(PING, new byte[0], 0, 0);
    }

    /** Sends one message. Safe to call from any thread. */
    void send(int opcode, byte[] payload, int offset, int count) throws IOException {
        int extra = count < 126 ? 0 : (count <= 0xFFFF ? 2 : 8);
        byte[] frame = new byte[2 + extra + 4 + count];
        int position = 0;
        frame[position++] = (byte) (0x80 | opcode);
        if (count < 126) {
            frame[position++] = (byte) (0x80 | count);
        } else if (count <= 0xFFFF) {
            frame[position++] = (byte) (0x80 | 126);
            frame[position++] = (byte) (count >>> 8);
            frame[position++] = (byte) count;
        } else {
            frame[position++] = (byte) (0x80 | 127);
            for (int shift = 56; shift >= 0; shift -= 8) frame[position++] = (byte) ((long) count >>> shift);
        }
        byte[] mask = new byte[4];   // clients must mask what they send
        random.nextBytes(mask);
        System.arraycopy(mask, 0, frame, position, 4);
        position += 4;
        for (int i = 0; i < count; i++) frame[position + i] = (byte) (payload[offset + i] ^ mask[i & 3]);
        synchronized (writeLock) {
            out.write(frame);
            out.flush();
        }
    }

    /** Ends the connection; a thread waiting in {@link #readMessage()} gets an IOException. */
    void close() {
        try {
            socket.close();
        } catch (IOException ignored) {
            // already closed
        }
    }

    private int readByte() throws IOException {
        int b = in.read();
        if (b < 0) throw new EOFException("connection closed");
        return b;
    }

    private void readFully(byte[] target, int count) throws IOException {
        int done = 0;
        while (done < count) {
            int n = in.read(target, done, count - done);
            if (n < 0) throw new EOFException("connection closed");
            done += n;
        }
    }

    static String base64(byte[] data) {
        StringBuilder text = new StringBuilder((data.length + 2) / 3 * 4);
        for (int i = 0; i < data.length; i += 3) {
            int b0 = data[i] & 0xFF;
            int b1 = i + 1 < data.length ? data[i + 1] & 0xFF : 0;
            int b2 = i + 2 < data.length ? data[i + 2] & 0xFF : 0;
            text.append(BASE64[b0 >>> 2]);
            text.append(BASE64[((b0 & 0x03) << 4) | (b1 >>> 4)]);
            text.append(i + 1 < data.length ? BASE64[((b1 & 0x0F) << 2) | (b2 >>> 6)] : '=');
            text.append(i + 2 < data.length ? BASE64[b2 & 0x3F] : '=');
        }
        return text.toString();
    }

    private static byte[] sha1(String text) throws IOException {
        try {
            return MessageDigest.getInstance("SHA-1").digest(text.getBytes(UTF8));
        } catch (NoSuchAlgorithmException e) {
            throw new IOException("SHA-1 missing", e);
        }
    }
}
