# JBoss EAP 8.1 server.log 対応一式

JBoss EAP の `server.log` が、日付をまたいだ後も `server.log.<前日>` に追記され続け、`server.log` に書かれない問題の再現・診断・対策です。
原因と考え方は `../Log4j2_EFS_ローリングアップデート_FD競合_完全解説.md` の **第16章**、Excel の **14〜19 シート**を参照してください。

| パス | 用途 |
|---|---|
| `repro/run_repro.sh` | EAP 8.1 と同じ jboss-logmanager 2.1.19.Final ＋ wildfly-common 1.7.0.Final で原因候補1〜4を再現する（Java 17 以上。JBoss 本体は不要）。`--reload4j` で原因候補1b（アプリ同梱 reload4j との共存）を再現。引数に EFS 上のパスを渡すと EFS 上で再現 |
| `repro/ServerLogRotationRepro.java` | 再現プログラム本体 |
| `repro/expected_output.txt` | 2026-09-24 の実行結果 |
| `repro/MixedLibraryRepro.java` | 原因候補1b の再現プログラム（JBoss FILE ＋ reload4j 1.2.26 の DailyRollingFileAppender） |
| `repro/expected_output_reload4j.txt` | 上記の実行結果 |
| `bin/check-server-log-fd.sh` | 実行時診断。`/proc/*/fd` から `server.log*` を指す FD を調べ、原因候補を判定（終了コード 0=正常 / 1=異常 / 2=前提不足） |
| `bin/audit-logging-config.sh` | 静的点検。standalone.xml・logging.properties・WAR/EAR 同梱ログ設定・logrotate/cron・entrypoint を横断。WAR/EAR 内の設定は EAP 8.1 の仕様で「コンテナが読む／同梱 reload4j・log4j-core・logback が読む／無視」に分類して、実際に有効かを判定 |
| `cli/fix-server-log-single-writer.cli` | `server.log` を開くハンドラを FILE 1つにし、コンテナが読むデプロイメント内ログ設定（logging.properties 系）を無効化。※同梱 reload4j 等はアプリ側で出力先を変更する |
| `cli/server-log-to-stdout.cli` | 恒久策：`server.log` をやめて JSON で stdout に出す |
| `bin/entrypoint.sh` | タスクID／コンテナ名のディレクトリを作り、リダイレクトせずに JBoss を起動（TZ=Asia/Tokyo） |

## 使い方（最短）

```sh
# コンテナ内で（ECS Exec 等）
./check-server-log-fd.sh /mnt/efs/logs/<タスクID>/<front|back>
./audit-logging-config.sh --cli /entrypoint.sh
```

`check-server-log-fd.sh` を日次（0:05 など）で実行し、終了コード 1 をアラートにすると再発を検知できます。
