/*
 * JBoss EAP 8.x で起きやすい「原因候補1b」の再現：
 *   アプリが同梱した reload4j（log4j 1.x 互換）の DailyRollingFileAppender と、
 *   JBoss の FILE ハンドラ（jboss-logmanager の PeriodicRotatingFileHandler）が、
 *   同じ server.log を別々の FD で開き、別々に rename する。
 *
 *   EAP 8 ではコンテナが log4j 1.x を提供しなくなったため、log4j.xml を使い続けるアプリは
 *   reload4j 等を WAR に同梱する。そのアプリが log4j.xml で ${jboss.server.log.dir}/server.log を
 *   指していると、use-deployment-logging-config の設定に関係なく2人目の書き手になる。
 *   reload4j の既定の日付パターン '.'yyyy-MM-dd は JBoss の .yyyy-MM-dd と全く同じ名前を作る。
 *
 *   reload4j はログイベントの時刻ではなく実時計（System.currentTimeMillis）で回転を判定するため、
 *   このプログラムは両者の周期を「1分」にして、実際に分の境界をまたいで動かす（最大 70 秒ほどかかる）。
 *   周期が日でも分でも、回転の手順（close → 既存の日付ファイルを削除 → rename → 開き直し）は同じ。
 *
 * 実行: ./run_repro.sh --reload4j [出力ディレクトリ]
 */

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.time.LocalTime;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.logging.Level;
import java.util.stream.Stream;

import org.apache.log4j.DailyRollingFileAppender;
import org.apache.log4j.Logger;
import org.apache.log4j.PatternLayout;
import org.jboss.logmanager.ExtLogRecord;
import org.jboss.logmanager.formatters.PatternFormatter;
import org.jboss.logmanager.handlers.PeriodicRotatingFileHandler;

public class MixedLibraryRepro {

    public static void main(String[] args) throws Exception {
        Path dir = Paths.get(args.length > 0 ? args[0] : "repro-out").toAbsolutePath().resolve("S6_jboss_and_reload4j");
        if (Files.exists(dir)) {
            try (Stream<Path> s = Files.walk(dir)) {
                for (Path p : s.sorted(Comparator.reverseOrder()).toList()) {
                    Files.delete(p);
                }
            }
        }
        Files.createDirectories(dir);
        Path serverLog = dir.resolve("server.log");

        System.out.println("==========================================================================");
        System.out.println("S6_jboss_and_reload4j : 原因候補1b：JBoss の FILE と、アプリ同梱 reload4j の DailyRollingFileAppender が同じ server.log を使う");
        System.out.println("==========================================================================");

        // 分の境界の 5 秒前まで待つ（起動直後に境界をまたがないようにする）
        int sec = LocalTime.now().getSecond();
        int wait = sec <= 50 ? 55 - sec : 60 - sec + 55;
        System.out.println("  分の境界の直前まで " + wait + " 秒待ちます…");
        Thread.sleep(wait * 1000L);

        // JBoss の FILE ハンドラ（standalone.xml の FILE と同じ設定。周期だけ分にしている）
        PeriodicRotatingFileHandler file = new PeriodicRotatingFileHandler();
        file.setAutoFlush(true);
        file.setAppend(true);
        file.setFormatter(new PatternFormatter("FILE     | %d{HH:mm:ss} %s%n"));
        file.setSuffix(".yyyy-MM-dd-HH-mm");
        file.setFile(serverLog.toFile());

        // アプリ同梱の reload4j（log4j.xml の <appender class="org.apache.log4j.DailyRollingFileAppender"> 相当）
        DailyRollingFileAppender app = new DailyRollingFileAppender(
                new PatternLayout("RELOAD4J | %d{HH:mm:ss} %m%n"), serverLog.toString(), "'.'yyyy-MM-dd-HH-mm");
        app.setImmediateFlush(true);
        Logger appLogger = Logger.getLogger("app");
        appLogger.setAdditivity(false);
        appLogger.addAppender(app);

        // 境界をまたいで 10 秒間、1 秒ごとに両方へ書く（JBoss → アプリ の順）
        for (int i = 0; i < 10; i++) {
            String msg = "ログ " + (i + 1) + " 件目";
            file.publish(new ExtLogRecord(Level.INFO, msg, MixedLibraryRepro.class.getName()));
            appLogger.info(msg);
            Thread.sleep(1000);
        }

        System.out.println();
        System.out.println("  ■ この JVM が開いている FD（/proc/self/fd）");
        List<String> fds = new ArrayList<>();
        try (Stream<Path> s = Files.list(Paths.get("/proc/self/fd"))) {
            s.forEach(p -> {
                try {
                    String t = Files.readSymbolicLink(p).toString();
                    if (t.startsWith(dir.toString())) {
                        fds.add("    fd " + p.getFileName() + " -> " + t.substring(dir.toString().length() + 1));
                    }
                } catch (Exception ignored) {
                }
            });
        }
        fds.sort(Comparator.naturalOrder());
        fds.forEach(System.out::println);
        System.out.println("    ※ JBoss の FILE も reload4j も「server.log に書いているつもり」");

        System.out.println();
        System.out.println("  ■ ディレクトリの状態と中身");
        try (Stream<Path> s = Files.list(dir)) {
            for (Path p : s.sorted().toList()) {
                System.out.println("    " + p.getFileName() + "  (" + Files.size(p) + " bytes)");
                for (String line : Files.readAllLines(p, StandardCharsets.UTF_8)) {
                    System.out.println("        " + line);
                }
            }
        }
        System.out.println();
        System.out.println("  期待される結果：境界より前の行（前の分）は消え、JBoss の FILE は境界後もずっと");
        System.out.println("  server.log.<前の分> に書き続け、server.log には RELOAD4J の行だけが入る。");

        file.close();
        app.close();
    }
}
