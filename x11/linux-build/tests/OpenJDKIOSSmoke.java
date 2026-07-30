import java.awt.Color;
import java.awt.Graphics2D;
import java.awt.image.BufferedImage;
import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Duration;
import java.util.HexFormat;
import java.util.concurrent.TimeUnit;
import javax.imageio.ImageIO;
import javax.net.ssl.SSLContext;

public final class OpenJDKIOSSmoke {
    private static long hotLoop(int rounds) {
        long value = 0x1234_5678L;
        for (int i = 0; i < rounds; i++) {
            value = Long.rotateLeft(value ^ i, 7) * 0x9e37_79b9L + 0x7f4a_7c15L;
        }
        return value;
    }

    public static void main(String[] args) throws Exception {
        System.out.println("java.version=" + System.getProperty("java.version"));
        System.out.println("java.vm.name=" + System.getProperty("java.vm.name"));
        System.out.println("java.vm.info=" + System.getProperty("java.vm.info"));
        System.out.println("os.name=" + System.getProperty("os.name"));
        System.out.println("os.arch=" + System.getProperty("os.arch"));
        System.out.println("headless=" + java.awt.GraphicsEnvironment.isHeadless());

        long checksum = 0;
        for (int i = 0; i < 400; i++) {
            checksum ^= hotLoop(25_000 + (i & 255));
        }
        System.out.println("jit.checksum=" + Long.toUnsignedString(checksum, 16));

        Process child = new ProcessBuilder("/var/jb/usr/bin/sh", "-c", "printf process-builder-ok")
                .redirectErrorStream(true)
                .start();
        if (!child.waitFor(10, TimeUnit.SECONDS)) {
            child.destroyForcibly();
            throw new IllegalStateException("ProcessBuilder child timed out");
        }
        String childOutput = new String(child.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
        System.out.println("child.exit=" + child.exitValue());
        System.out.println("child.output=" + childOutput);

        BufferedImage image = new BufferedImage(32, 32, BufferedImage.TYPE_INT_ARGB);
        Graphics2D graphics = image.createGraphics();
        graphics.setColor(new Color(0x33, 0x99, 0xff, 0xff));
        graphics.fillRect(0, 0, image.getWidth(), image.getHeight());
        graphics.dispose();
        ByteArrayOutputStream png = new ByteArrayOutputStream();
        if (!ImageIO.write(image, "png", png)) {
            throw new IllegalStateException("No PNG ImageIO writer");
        }
        byte[] pngBytes = png.toByteArray();
        String pngHash = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(pngBytes));
        System.out.println("imageio.png.bytes=" + pngBytes.length);
        System.out.println("imageio.png.sha256=" + pngHash);

        SSLContext tls = SSLContext.getDefault();
        System.out.println("tls.protocol=" + tls.getProtocol());
        System.out.println("http.client=" + Class.forName("java.net.http.HttpClient").getName());

        if (args.length == 1 && args[0].equals("--network")) {
            HttpClient client = HttpClient.newBuilder()
                    .connectTimeout(Duration.ofSeconds(10))
                    .followRedirects(HttpClient.Redirect.NORMAL)
                    .build();
            HttpRequest request = HttpRequest.newBuilder(URI.create("https://example.com/"))
                    .timeout(Duration.ofSeconds(15))
                    .GET()
                    .build();
            HttpResponse<Void> response = client.send(request, HttpResponse.BodyHandlers.discarding());
            System.out.println("https.status=" + response.statusCode());
        }

        if (!childOutput.equals("process-builder-ok") || child.exitValue() != 0) {
            throw new IllegalStateException("ProcessBuilder failed");
        }
        System.out.println("OPENJDK_IOS_SMOKE_OK");
    }
}
