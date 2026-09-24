/*
 * JBoss EAP の server.log が「日付をまたいだ後も server.log.YYYY-MM-DD に追記され続ける」
 * 現象を、JBoss EAP が実際に使っている jboss-logmanager の PeriodicRotatingFileHandler
 * そのもので再現するプログラム。
 *
 *   - JBoss EAP / WildFly 本体は不要。jboss-logmanager の jar 1つだけで動く。
 *   - 時計は進めない。ログレコードのタイムスタンプを 2026-09-18 23:59 〜 2026-09-19 00:00 に
 *     直接設定して「日付またぎ」を起こす（PeriodicRotatingFileHandler はタイマーではなく、
 *     レコードの時刻で回転を判定するため、これで本物と同じ分岐を通る）。
 *   - 各シナリオの最後に、/proc/self/fd を読んで「各ハンドラの FD がどのファイル名を指しているか」
 *     と、各ファイルの inode 番号・中身を表示する。
 *
 * 実行: ./run_repro.sh   （jar の取得と実行をまとめて行う）
 *   または java -cp jboss-logmanager-2.1.19.Final.jar ServerLogRotationRepro.java [作業ディレクトリ]
 *
 * 作業ディレクトリに EFS（NFS）上のパスを渡せば、EFS 上での挙動もそのまま確認できる。
 */

import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.TimeZone;
import java.util.logging.Level;
import java.util.stream.Stream;

import org.jboss.logmanager.ExtLogRecord;
import org.jboss.logmanager.formatters.PatternFormatter;
import org.jboss.logmanager.handlers.PeriodicRotatingFileHandler;

public class ServerLogRotationRepro {

    static final ZoneId JST = ZoneId.of("Asia/Tokyo");
    static final String SUFFIX = ".yyyy-MM-dd";   // standalone.xml の既定値と同じ

    static Path baseDir;

    public static void main(String[] args) throws Exception {
        // コンテナを TZ=Asia/Tokyo で動かしている想定（シナリオ6だけ UTC に切り替える）
        TimeZone.setDefault(TimeZone.getTimeZone(JST));
        baseDir = Paths.get(args.length > 0 ? args[0] : "repro-out").toAbsolutePath();
        deleteRecursively(baseDir);
        Files.createDirectories(baseDir);

        scenario0_baseline();
        scenario1_twoHandlersSameFile();
        scenario2_externalRenameAfterJBoss();
        scenario3_externalRenameBeforeJBoss();
        scenario4_stdoutRedirectedToServerLog();
        scenario5_timezoneMismatch();

        System.out.println();
        System.out.println("出力ディレクトリ: " + baseDir);
    }

    // ------------------------------------------------------------------------------------------
    // シナリオ0: 正常系（1ファイル = 1ハンドラ = 1FD、外部からの rename なし）
    // ------------------------------------------------------------------------------------------
    static void scenario0_baseline() throws Exception {
        Path dir = scenarioDir("S0_baseline", "正常系：server.log を開くのは FILE ハンドラ1つだけ");
        Path serverLog = prepareServerLog(dir);
        PeriodicRotatingFileHandler file = handler("FILE", serverLog);

        logAt(at(2026, 9, 18, 23, 59, 50), "日付またぎ前のログ", file);
        logAt(at(2026, 9, 19, 0, 0, 10), "日付またぎ後のログ(1件目) ← ここで回転", file);
        logAt(at(2026, 9, 19, 0, 0, 40), "日付またぎ後のログ(2件目)", file);

        report(dir, List.of(new Named("FILE", file)));
        file.close();
    }

    // ------------------------------------------------------------------------------------------
    // シナリオ1: 同じ JVM の中で、server.log を指すハンドラが2つある
    //   （例: subsystem の FILE と、logging-profile / デプロイメント内 logging 設定 /
    //    CLI で追加した別名ハンドラ が同じ path=server.log を指している）
    // ------------------------------------------------------------------------------------------
    static void scenario1_twoHandlersSameFile() throws Exception {
        Path dir = scenarioDir("S1_two_handlers_same_file",
                "原因候補1：同一JVM内に server.log を開くハンドラが2つ（FILE と APP_FILE）");
        Path serverLog = prepareServerLog(dir);
        // 1つのロガーに FILE → APP_FILE の順で付いている想定（同じレコードが順に2つのハンドラへ渡る）
        PeriodicRotatingFileHandler file = handler("FILE", serverLog);
        PeriodicRotatingFileHandler app = handler("APP_FILE", serverLog);

        logAt(at(2026, 9, 18, 23, 59, 50), "9/18 最後のログ（本来 server.log.2026-09-18 に残るべき）", file, app);
        logAt(at(2026, 9, 19, 0, 0, 10), "9/19 最初のログ ← ここで FILE が回転し、直後に APP_FILE も回転", file, app);
        logAt(at(2026, 9, 19, 0, 0, 40), "9/19 2件目のログ", file, app);
        logAt(at(2026, 9, 19, 12, 0, 0), "9/19 昼のログ", file, app);
        report(dir, List.of(new Named("FILE", file), new Named("APP_FILE", app)));

        System.out.println();
        System.out.println("  --- 翌日（9/20 0時）も同じことが繰り返されるか ---");
        logAt(at(2026, 9, 20, 0, 0, 10), "9/20 最初のログ ← 再び FILE → APP_FILE の順に回転", file, app);
        logAt(at(2026, 9, 20, 0, 0, 40), "9/20 2件目のログ", file, app);
        report(dir, List.of(new Named("FILE", file), new Named("APP_FILE", app)));
        file.close();
        app.close();
    }

    // ------------------------------------------------------------------------------------------
    // シナリオ2: JBoss の回転「後」に、外部（logrotate / 収集バッチ / 別ホストの cron）が
    //   server.log を server.log.2026-09-18 に rename して、空の server.log を作る
    // ------------------------------------------------------------------------------------------
    static void scenario2_externalRenameAfterJBoss() throws Exception {
        Path dir = scenarioDir("S2_external_rename_after_jboss",
                "原因候補3a：JBoss が回転した直後に、外部の仕組みが server.log を日付名へ rename");
        Path serverLog = prepareServerLog(dir);
        PeriodicRotatingFileHandler file = handler("FILE", serverLog);

        logAt(at(2026, 9, 18, 23, 59, 50), "9/18 最後のログ（本来 server.log.2026-09-18 に残るべき）", file);
        logAt(at(2026, 9, 19, 0, 0, 10), "9/19 最初のログ ← ここで JBoss が回転", file);
        externalRotate(serverLog, "2026-09-18", "00:00:30 外部の logrotate 相当が mv server.log server.log.2026-09-18 && touch server.log");
        logAt(at(2026, 9, 19, 0, 0, 40), "9/19 2件目のログ", file);
        logAt(at(2026, 9, 19, 12, 0, 0), "9/19 昼のログ", file);

        report(dir, List.of(new Named("FILE", file)));
        file.close();
    }

    // ------------------------------------------------------------------------------------------
    // シナリオ3: JBoss の回転「前」に、外部が server.log を rename
    // ------------------------------------------------------------------------------------------
    static void scenario3_externalRenameBeforeJBoss() throws Exception {
        Path dir = scenarioDir("S3_external_rename_before_jboss",
                "原因候補3b：JBoss が回転する前（時境界直後）に、外部の仕組みが server.log を rename");
        Path serverLog = prepareServerLog(dir);
        PeriodicRotatingFileHandler file = handler("FILE", serverLog);

        logAt(at(2026, 9, 18, 23, 59, 50), "9/18 最後のログ（本来 server.log.2026-09-18 に残るべき）", file);
        externalRotate(serverLog, "2026-09-18", "00:00:01 外部の logrotate 相当が mv server.log server.log.2026-09-18 && touch server.log");
        logAt(at(2026, 9, 19, 0, 0, 10), "9/19 最初のログ ← ここで JBoss が回転（外部が作った空の server.log を日付名へ上書き）", file);
        logAt(at(2026, 9, 19, 0, 0, 40), "9/19 2件目のログ", file);

        report(dir, List.of(new Named("FILE", file)));
        file.close();
    }

    // ------------------------------------------------------------------------------------------
    // シナリオ4: entrypoint で `standalone.sh >> server.log 2>&1` のように
    //   JVM の stdout/stderr を同じ server.log へリダイレクトしている
    //   （シェルが開いた FD 1/2 は JBoss の回転を知らない）
    // ------------------------------------------------------------------------------------------
    static void scenario4_stdoutRedirectedToServerLog() throws Exception {
        Path dir = scenarioDir("S4_stdout_redirect",
                "原因候補2：JVM の stdout を server.log へリダイレクト（CONSOLE ハンドラの出力がそこへ行く）");
        Path serverLog = prepareServerLog(dir);
        // シェルの `>> server.log` に相当：JVM 起動前に O_APPEND で開かれ、以後閉じられない FD
        FileOutputStream shellStdout = new FileOutputStream(serverLog.toFile(), true);
        PeriodicRotatingFileHandler file = handler("FILE", serverLog);

        logAt(at(2026, 9, 18, 23, 59, 50), "9/18 最後のログ", file);
        console(shellStdout, at(2026, 9, 18, 23, 59, 50), "9/18 最後のログ");
        logAt(at(2026, 9, 19, 0, 0, 10), "9/19 最初のログ ← FILE だけが回転する", file);
        console(shellStdout, at(2026, 9, 19, 0, 0, 10), "9/19 最初のログ");
        logAt(at(2026, 9, 19, 0, 0, 40), "9/19 2件目のログ", file);
        console(shellStdout, at(2026, 9, 19, 0, 0, 40), "9/19 2件目のログ");

        report(dir, List.of(new Named("FILE", file), new Named("stdout(シェルのリダイレクト)", null)));
        file.close();
        shellStdout.close();
    }

    // ------------------------------------------------------------------------------------------
    // シナリオ5: JVM のタイムゾーンが UTC（コンテナ既定）のまま
    //   → 「日付またぎ」は JST 09:00 に起きる。JST 0 時には何も起きない。
    //   → 後から見ると server.log.2026-09-18 に JST 9/19 0〜9時のログが入っており、
    //     「前日付ファイルに追記された」ように見える（ただし 0〜9時の間は server.log が伸びている）。
    // ------------------------------------------------------------------------------------------
    static void scenario5_timezoneMismatch() throws Exception {
        Path dir = scenarioDir("S5_timezone_utc",
                "原因候補4（見かけ上の類似）：JVM が UTC のまま（回転は JST 09:00。日付ファイルに JST 0〜9時のログが入る）");
        Path serverLog = prepareServerLog(dir);
        PeriodicRotatingFileHandler file = handler("FILE", serverLog);
        file.setTimeZone(TimeZone.getTimeZone("UTC"));
        // setTimeZone 後に lastModified から次回回転時刻を計算し直させる
        file.setSuffix(SUFFIX);

        logAt(at(2026, 9, 18, 23, 59, 50), "JST 9/18 23:59:50", file);
        logAt(at(2026, 9, 19, 0, 0, 10), "JST 9/19 00:00:10（UTC ではまだ 9/18 15:00。回転しない）", file);
        logAt(at(2026, 9, 19, 8, 59, 50), "JST 9/19 08:59:50", file);
        logAt(at(2026, 9, 19, 9, 0, 10), "JST 9/19 09:00:10（UTC で日付が変わる → ここで回転）", file);

        report(dir, List.of(new Named("FILE", file)));
        file.close();
    }

    // ------------------------------------------------------------------------------------------
    // 補助
    // ------------------------------------------------------------------------------------------

    record Named(String name, PeriodicRotatingFileHandler handler) { }

    static Path scenarioDir(String name, String title) throws IOException {
        System.out.println();
        System.out.println("==========================================================================");
        System.out.println(name + " : " + title);
        System.out.println("==========================================================================");
        Path dir = baseDir.resolve(name);
        Files.createDirectories(dir);
        return dir;
    }

    /** 前日から稼働しているタスクを模擬：server.log の mtime を 9/18 23:59:00 にしておく。 */
    static Path prepareServerLog(Path dir) throws IOException {
        Path serverLog = dir.resolve("server.log");
        Files.writeString(serverLog, "");
        serverLog.toFile().setLastModified(at(2026, 9, 18, 23, 59, 0));
        return serverLog;
    }

    static PeriodicRotatingFileHandler handler(String name, Path serverLog) throws IOException {
        PeriodicRotatingFileHandler h = new PeriodicRotatingFileHandler();
        h.setAutoFlush(true);
        h.setAppend(true);
        h.setFormatter(new PatternFormatter(String.format("%-8s", name) + " | %d{yyyy-MM-dd HH:mm:ss} %s%n"));
        h.setSuffix(SUFFIX);
        h.setFile(serverLog.toFile());   // ← ここで FileOutputStream(server.log, append) が開かれる
        return h;
    }

    static long at(int y, int mo, int d, int h, int mi, int s) {
        return LocalDateTime.of(y, mo, d, h, mi, s).atZone(JST).toInstant().toEpochMilli();
    }

    @SuppressWarnings("deprecation")
    static void logAt(long millis, String msg, PeriodicRotatingFileHandler... handlers) {
        for (PeriodicRotatingFileHandler h : handlers) {
            ExtLogRecord r = new ExtLogRecord(Level.INFO, msg, ServerLogRotationRepro.class.getName());
            r.setMillis(millis);
            h.publish(r);
        }
    }

    static void console(FileOutputStream out, long millis, String msg) throws IOException {
        String ts = LocalDateTime.ofInstant(java.time.Instant.ofEpochMilli(millis), JST).toString().replace('T', ' ');
        out.write(String.format("%-8s | %s %s%n", "CONSOLE", ts, msg).getBytes(StandardCharsets.UTF_8));
        out.flush();
    }

    /** logrotate の既定動作（rename → create）と同じことを外部から行う。 */
    static void externalRotate(Path serverLog, String date, String note) throws IOException {
        System.out.println("  [外部] " + note);
        Path target = serverLog.resolveSibling(serverLog.getFileName() + "." + date);
        Files.move(serverLog, target, java.nio.file.StandardCopyOption.REPLACE_EXISTING);
        Files.writeString(serverLog, "");
    }

    static void report(Path dir, List<Named> named) throws IOException {
        System.out.println();
        System.out.println("  ■ この JVM が開いている FD（/proc/self/fd）");
        List<String> fds = new ArrayList<>();
        try (Stream<Path> s = Files.list(Paths.get("/proc/self/fd"))) {
            s.forEach(p -> {
                try {
                    Path t = Files.readSymbolicLink(p);
                    if (t.toString().startsWith(dir.toString())) {
                        fds.add("    fd " + p.getFileName() + " -> " + dir.relativize(Paths.get(t.toString().replace(" (deleted)", ""))) + (t.toString().endsWith(" (deleted)") ? "  (deleted)" : ""));
                    }
                } catch (IOException ignored) {
                }
            });
        }
        fds.sort(Comparator.naturalOrder());
        fds.forEach(System.out::println);
        for (Named n : named) {
            if (n.handler() != null) {
                System.out.println("    ※ " + n.name() + " ハンドラ自身は getFile()=" + dir.relativize(n.handler().getFile().toPath())
                        + " に書いているつもり");
            }
        }

        System.out.println();
        System.out.println("  ■ ディレクトリの状態と中身");
        try (Stream<Path> s = Files.list(dir)) {
            for (Path p : s.sorted().toList()) {
                Object ino = Files.getAttribute(p, "unix:ino");
                System.out.println("    " + p.getFileName() + "  (inode " + ino + ", " + Files.size(p) + " bytes)");
                for (String line : Files.readAllLines(p, StandardCharsets.UTF_8)) {
                    System.out.println("        " + line);
                }
                if (Files.size(p) == 0) {
                    System.out.println("        （空）");
                }
            }
        }
    }

    static void deleteRecursively(Path p) throws IOException {
        if (!Files.exists(p)) {
            return;
        }
        try (Stream<Path> s = Files.walk(p)) {
            for (Path x : s.sorted(Comparator.reverseOrder()).toList()) {
                Files.delete(x);
            }
        }
    }
}
