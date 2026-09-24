#!/bin/sh
# check-server-log-fd.sh
#   JBoss EAP の server.log について「誰が・何本の FD で・どの inode を」掴んでいるかを調べ、
#   server.log.YYYY-MM-DD へ追記され続ける原因を判定する。
#
#   使い方（コンテナ内で実行。ECS Exec 等で入る）:
#     check-server-log-fd.sh [ログディレクトリ] [ファイル名]
#       ログディレクトリ 既定: $JBOSS_LOG_DIR → 無ければ $JBOSS_HOME/standalone/log
#       ファイル名       既定: server.log
#
#   終了コード: 0 = 正常 / 1 = 異常を検出 / 2 = 使い方の誤り・前提不足
#
#   判定の考え方:
#     FD は「ファイル名」ではなく inode に結びつく。server.log を開いている FD が
#       - 同じ JVM の中に2本以上ある                → 原因候補1／1b（同一JVM内の複数ハンドラ／同梱ライブラリ）
#       - FD 番号 1/2（stdout/stderr）である        → 原因候補2（シェルのリダイレクト）
#       - JVM 以外のプロセス（tee 等）が持っている   → 原因候補2の変形
#       - 1本だけだが server.log.<日付> を指している → 原因候補3（外部からの rename）
#       - 名前は server.log だが inode が一致しない   → 原因候補3（別ホストからの rename）
set -u

LOG_DIR="${1:-${JBOSS_LOG_DIR:-${JBOSS_HOME:-/opt/jboss}/standalone/log}}"
BASE="${2:-server.log}"

if [ ! -d "$LOG_DIR" ]; then
  echo "ログディレクトリがありません: $LOG_DIR" >&2
  exit 2
fi
if [ ! -d /proc/self/fd ]; then
  echo "/proc が見えません（Linux のコンテナ内で実行してください）" >&2
  exit 2
fi

LOG_DIR=$(cd "$LOG_DIR" && pwd -P)
CUR="$LOG_DIR/$BASE"
CUR_INO=""
[ -e "$CUR" ] && CUR_INO=$(stat -c '%i' "$CUR")

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT INT TERM

# 収集: pid<TAB>comm<TAB>fd<TAB>リンク先<TAB>実inode
for p in /proc/[0-9]*; do
  pid=${p#/proc/}
  [ "$pid" = "$$" ] && continue
  [ -r "$p/fd" ] || continue
  comm=$(cat "$p/comm" 2>/dev/null || echo '?')
  for f in "$p"/fd/*; do
    t=$(readlink "$f" 2>/dev/null) || continue
    case "$t" in
      "$LOG_DIR/$BASE"|"$LOG_DIR/$BASE".*|"$LOG_DIR/$BASE (deleted)"|"$LOG_DIR"/.nfs*)
        ino=$(stat -L -c '%i' "$f" 2>/dev/null || echo '?')
        printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$comm" "${f##*/}" "$t" "$ino" >> "$TMP"
        ;;
    esac
  done
done

echo "== 対象: $CUR  (現在の inode: ${CUR_INO:-存在しない})"
echo
echo "== ディレクトリの状態"
ls -li "$LOG_DIR" | grep -E " ${BASE}(\..*)?\$| \.nfs" || echo "  （該当ファイルなし）"
echo
echo "== ${BASE}* を開いている FD"
if [ ! -s "$TMP" ]; then
  echo "  （どのプロセスも開いていません。JBoss の起動前か、別コンテナ／別ホストで動いています）"
  exit 2
fi
printf '  %-7s %-16s %-4s %-12s %s\n' PID COMM FD INODE 指している名前
while IFS="$(printf '\t')" read -r pid comm fd t ino; do
  printf '  %-7s %-16s %-4s %-12s %s\n' "$pid" "$comm" "$fd" "$ino" "${t#"$LOG_DIR"/}"
done < "$TMP"
echo

NG=0
say() { echo "  [$1] $2"; }

# --- 判定1: 同一プロセス内に stdout/stderr 以外の FD が2本以上（原因候補1）
MULTI=$(awk -F'\t' '$3!=1 && $3!=2 {n[$1]++; c[$1]=$2} END {for (p in n) if (n[p]>=2) print p"\t"c[p]"\t"n[p]}' "$TMP")
if [ -n "$MULTI" ]; then
  echo "$MULTI" |
  while IFS="$(printf '\t')" read -r pid comm n; do
    say "原因候補1" "PID $pid ($comm) が ${BASE}* を ${n} 本の FD で開いています。同じ JVM の中に ${BASE} を開く書き手が複数あります（原因候補1：subsystem の別名ハンドラ／logging-profile／デプロイメント内の logging.properties・jboss-logging.properties、原因候補1b：アプリが同梱した reload4j の log4j.xml や log4j-core・logback の設定）。audit-logging-config.sh で特定してください。"
  done
  NG=1
fi

# --- 判定2: FD 1/2（stdout/stderr）が server.log* を指している（原因候補2）
if awk -F'\t' '$3==1 || $3==2 {f=1} END {exit !f}' "$TMP"; then
  awk -F'\t' '$3==1 || $3==2 {print $1"\t"$2"\t"$3}' "$TMP" | sort -u |
  while IFS="$(printf '\t')" read -r pid comm fd; do
    say "原因候補2" "PID $pid ($comm) の FD $fd（stdout/stderr）が ${BASE}* を指しています。entrypoint 等で 'standalone.sh >> ${BASE} 2>&1' のようにリダイレクトしていませんか。シェルが開いた FD は JBoss の回転を知りません。"
  done
  NG=1
fi

# --- 判定2': java 以外のプロセスが開いている（tee、tail -f 以外の書き手など）
if awk -F'\t' '$2!="java" && $3!=1 && $3!=2 {f=1} END {exit !f}' "$TMP"; then
  awk -F'\t' '$2!="java" && $3!=1 && $3!=2 {print $1"\t"$2}' "$TMP" | sort -u |
  while IFS="$(printf '\t')" read -r pid comm; do
    say "要確認" "java 以外のプロセス PID $pid ($comm) が ${BASE}* を開いています。tee や独自の転送プロセスなら書き手になっていないか確認してください（tail -f など読むだけなら無害です）。"
  done
fi

# --- 判定3: 現行名以外（回転済みの名前）を指している FD
if awk -F'\t' -v cur="$CUR" '$4!=cur && $4 !~ /\(deleted\)$/ {f=1} END {exit !f}' "$TMP"; then
  awk -F'\t' -v cur="$CUR" '$4!=cur && $4 !~ /\(deleted\)$/ {print $1"\t"$2"\t"$3"\t"$4}' "$TMP" |
  while IFS="$(printf '\t')" read -r pid comm fd t; do
    say "発生中" "PID $pid ($comm) の FD $fd は ${t#"$LOG_DIR"/} に書いています（${BASE} に書いていません）。"
  done
  # 判定1・2 に当たらないなら、外部からの rename が原因
  if [ -z "$MULTI" ] && ! awk -F'\t' '$3==1 || $3==2 {f=1} END {exit !f}' "$TMP"; then
    say "原因候補3" "JVM 内の FD は1本だけなのに回転済みの名前を指しています。JBoss 以外の何か（logrotate、収集バッチ、別ホストの cron、運用手順の mv）が ${BASE} を rename しています。"
  fi
  NG=1
fi

# --- 判定3': 名前は server.log のままだが inode が現在の server.log と違う（別ホストからの rename）
if [ -n "$CUR_INO" ]; then
  if awk -F'\t' -v cur="$CUR" -v ci="$CUR_INO" '$4==cur && $5!=ci && $5!="?" {f=1} END {exit !f}' "$TMP"; then
    awk -F'\t' -v cur="$CUR" -v ci="$CUR_INO" '$4==cur && $5!=ci && $5!="?" {print $1"\t"$2"\t"$3"\t"$5}' "$TMP" |
    while IFS="$(printf '\t')" read -r pid comm fd ino; do
      say "原因候補3" "PID $pid ($comm) の FD $fd は名前上は ${BASE} ですが inode $ino を指しており、現在の ${BASE}（inode $CUR_INO）とは別物です。別ホスト（別の NFS クライアント）が rename した可能性が高いです。"
    done
    NG=1
  fi
fi

# --- 補足: 削除済み・.nfs*
if awk -F'\t' '$4 ~ /\(deleted\)$/ || $4 ~ /\/\.nfs/ {f=1} END {exit !f}' "$TMP"; then
  say "データ消失" "削除済み（または .nfs* に化けた）inode に書いている FD があります。回転時の上書き（Files.move REPLACE_EXISTING）で前日分が消えています。"
  NG=1
fi

if [ "$NG" -eq 0 ]; then
  say "正常" "${BASE} を開いている FD は JVM 内に1本だけで、現在の ${BASE}（inode $CUR_INO）を指しています。"
  exit 0
fi
exit 1
