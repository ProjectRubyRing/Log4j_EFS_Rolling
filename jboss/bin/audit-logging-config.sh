#!/bin/sh
# audit-logging-config.sh
#   「server.log を開く／rename する主体が JBoss の FILE ハンドラ1つだけか」を、設定・デプロイメント・
#   OS 側の仕組みまで横断して静的に点検する。check-server-log-fd.sh（実行時の FD 点検）で
#   原因候補1〜3 が出たときに、その“犯人”の定義箇所を特定するために使う。
#
#   使い方:
#     audit-logging-config.sh [--cli] [点検したい追加ファイル ...]
#       --cli   稼働中の JBoss に jboss-cli.sh で接続し、実行時のハンドラ定義も表示する
#       追加ファイル  entrypoint.sh / Dockerfile / タスク定義 JSON など（リダイレクトの有無を点検）
#
#   環境変数:
#     JBOSS_HOME      既定 /opt/jboss
#     JBOSS_CONFIG    既定 $JBOSS_HOME/standalone/configuration/standalone.xml
#     DEPLOY_DIR      既定 $JBOSS_HOME/standalone/deployments
#     LOG_BASENAME    既定 server.log
#
#   終了コード: 0 = 指摘なし / 1 = 指摘あり
set -u

USE_CLI=0
if [ "${1:-}" = "--cli" ]; then
  USE_CLI=1
  shift
fi

JBOSS_HOME="${JBOSS_HOME:-/opt/jboss}"
JBOSS_CONFIG="${JBOSS_CONFIG:-$JBOSS_HOME/standalone/configuration/standalone.xml}"
BOOT_PROPS="$(dirname "$JBOSS_CONFIG")/logging.properties"
DEPLOY_DIR="${DEPLOY_DIR:-$JBOSS_HOME/standalone/deployments}"
LOG_BASENAME="${LOG_BASENAME:-server.log}"

# 指摘の有無はファイルで持つ（while ループがパイプのサブシェルで動くため、変数では親に伝わらない）
FLAG=$(mktemp)
trap 'rm -f "$FLAG"' EXIT INT TERM
hdr()  { echo; echo "== $1"; }
warn() { echo "  [指摘] $1"; echo x > "$FLAG"; }
info() { echo "  [情報] $1"; }

# -------------------------------------------------------------------------------------------
# 1. standalone.xml：ファイル系ハンドラ（logging-profile 内を含む）の出力先一覧と重複検出
# -------------------------------------------------------------------------------------------
hdr "1. logging subsystem のファイル系ハンドラ（$JBOSS_CONFIG）"
if [ -r "$JBOSS_CONFIG" ]; then
  LIST=$(awk '
    /<subsystem xmlns="urn:jboss:domain:logging:/ { inlog=1 }
    inlog && /<\/subsystem>/                      { inlog=0 }
    !inlog { next }
    /<logging-profile / { match($0, /name="[^"]*"/); prof=substr($0, RSTART+6, RLENGTH-7) }
    /<\/logging-profile>/ { prof="" }
    /<(periodic-rotating-file-handler|size-rotating-file-handler|periodic-size-rotating-file-handler|file-handler) / {
      match($0, /<[a-z-]+/); type=substr($0, RSTART+1, RLENGTH-1)
      match($0, /name="[^"]*"/); h=substr($0, RSTART+6, RLENGTH-7)
    }
    /<file / {
      rel="(絶対パス)"; path=""
      if (match($0, /relative-to="[^"]*"/)) rel=substr($0, RSTART+13, RLENGTH-14)
      if (match($0, /path="[^"]*"/))        path=substr($0, RSTART+6, RLENGTH-7)
      printf "%s\t%s\t%s\t%s\t%s\n", (prof=="" ? "(subsystem直下)" : "profile=" prof), h, type, rel, path
    }
  ' "$JBOSS_CONFIG")
  if [ -z "$LIST" ]; then
    info "ファイル系ハンドラは定義されていません"
  else
    printf '  %-24s %-20s %-36s %s\n' 場所 ハンドラ 種別 出力先
    echo "$LIST" | while IFS="$(printf '\t')" read -r where h type rel path; do
      printf '  %-24s %-20s %-36s %s/%s\n' "$where" "$h" "$type" "$rel" "$path"
    done
    DUP=$(echo "$LIST" | awk -F'\t' '{k=$4"/"$5; n[k]++; hs[k]=hs[k] " " $2 "(" $1 ")"} END {for (k in n) if (n[k]>1) print k "\t" hs[k]}')
    if [ -n "$DUP" ]; then
      echo "$DUP" | while IFS="$(printf '\t')" read -r k hs; do
        warn "同じファイル ${k} を複数のハンドラが開きます:${hs}  → 原因候補1。1ファイル=1ハンドラにしてください（fix-server-log-single-writer.cli）。"
      done
    fi
    echo "$LIST" | awk -F'\t' -v b="$LOG_BASENAME" '$5==b' | grep -q . ||
      info "${LOG_BASENAME} を出力先に持つハンドラが見つかりません（ハンドラ名やパスを確認してください）"
  fi
  if grep -q 'use-deployment-logging-config="false"' "$JBOSS_CONFIG"; then
    info "use-deployment-logging-config=false（デプロイメント内のログ設定ファイルは無視されます）"
  else
    info "use-deployment-logging-config は既定（true）です。デプロイメント内のログ設定ファイルが有効になります → 3 を確認"
  fi
else
  info "読めません: $JBOSS_CONFIG"
fi

# -------------------------------------------------------------------------------------------
# 2. 起動時ログ設定（logging.properties）
# -------------------------------------------------------------------------------------------
hdr "2. 起動時ログ設定（$BOOT_PROPS）"
if [ -r "$BOOT_PROPS" ]; then
  grep -nE '^handler\.[^.]+\.fileName=|^handler\.[^.]+=' "$BOOT_PROPS" | sed 's/^/  /'
  N=$(grep -cE '^handler\.[^.]+\.fileName=' "$BOOT_PROPS")
  if [ "$N" -gt 1 ]; then
    warn "起動時設定に fileName を持つハンドラが ${N} 個あります。同じファイルを指していないか確認してください。"
  fi
  info "logging.properties は subsystem 設定から自動生成されます。手で編集している場合は standalone.xml と食い違っていないか確認してください。"
else
  info "読めません: $BOOT_PROPS"
fi

# -------------------------------------------------------------------------------------------
# 3. デプロイメント内のログ設定（per-deployment logging）
# -------------------------------------------------------------------------------------------
hdr "3. デプロイメント内のログ設定ファイル（$DEPLOY_DIR）"
CONF_RE='(^|/)(logging\.properties|jboss-logging\.properties|log4j\.xml|jboss-log4j\.xml|log4j\.properties|log4j2[^/]*\.(xml|json|ya?ml|properties)|logback[^/]*\.xml)$'
scan_archive() {
  # $1 = アーカイブ, $2 = 表示用の名前
  command -v unzip >/dev/null 2>&1 || { info "unzip が無いため $2 の中身を点検できません"; return; }
  unzip -Z1 "$1" 2>/dev/null | grep -E "$CONF_RE" | while read -r e; do
    if unzip -p "$1" "$e" 2>/dev/null | grep -nE "${LOG_BASENAME}|jboss\.server\.log\.dir" >/dev/null; then
      warn "$2!/$e が ${LOG_BASENAME} または jboss.server.log.dir を参照しています → 原因候補1（JBoss の FILE とは別のハンドラ／アペンダが同じファイルを開き、しかも独自に rename します）"
      unzip -p "$1" "$e" | grep -nE "${LOG_BASENAME}|jboss\.server\.log\.dir" | sed 's/^/        /'
    else
      info "$2!/$e（${LOG_BASENAME} への参照なし）"
    fi
  done
  # EAR の中の WAR を1階層だけ展開して点検
  unzip -Z1 "$1" 2>/dev/null | grep -E '\.(war|jar)$' | while read -r inner; do
    t=$(mktemp)
    unzip -p "$1" "$inner" > "$t" 2>/dev/null && scan_archive "$t" "$2!/$inner"
    rm -f "$t"
  done
}
if [ -d "$DEPLOY_DIR" ]; then
  for d in "$DEPLOY_DIR"/*; do
    [ -e "$d" ] || continue
    case "$d" in
      *.war|*.ear|*.jar)
        if [ -d "$d" ]; then
          # 展開済みデプロイメント
          find "$d" -type f | grep -E "$CONF_RE" | while read -r f; do
            if grep -qE "${LOG_BASENAME}|jboss\.server\.log\.dir" "$f"; then
              warn "$f が ${LOG_BASENAME} または jboss.server.log.dir を参照しています → 原因候補1"
            else
              info "$f（${LOG_BASENAME} への参照なし）"
            fi
          done
        else
          scan_archive "$d" "${d##*/}"
        fi
        ;;
    esac
  done
else
  info "ディレクトリがありません: $DEPLOY_DIR"
fi

# -------------------------------------------------------------------------------------------
# 4. JBoss 以外に server.log を rename する仕組み（logrotate / cron）
# -------------------------------------------------------------------------------------------
hdr "4. JBoss 以外のローテーション（logrotate / cron）"
for f in /etc/logrotate.conf /etc/logrotate.d/* /etc/crontab /etc/cron.d/* /etc/cron.daily/* /etc/cron.hourly/* /var/spool/cron/* /var/spool/cron/crontabs/*; do
  [ -f "$f" ] || continue
  if grep -nE "${LOG_BASENAME}|jboss|/mnt/efs" "$f" >/dev/null 2>&1; then
    warn "$f が ${LOG_BASENAME}／jboss／EFS パスを扱っています → 原因候補3（JBoss は外部 rename 後にファイルを開き直しません）"
    grep -nE "${LOG_BASENAME}|jboss|/mnt/efs" "$f" | sed 's/^/        /'
  fi
done
info "このコンテナ外（ログ収集用 EC2・バッチ・運用手順）で ${LOG_BASENAME} を mv/rename していないかは別途確認してください。"

# -------------------------------------------------------------------------------------------
# 5. 追加ファイル（entrypoint / Dockerfile / タスク定義）のリダイレクト
# -------------------------------------------------------------------------------------------
hdr "5. 起動スクリプト等のリダイレクト"
if [ "$#" -eq 0 ]; then
  info "追加ファイルの指定なし（例: audit-logging-config.sh /entrypoint.sh /Dockerfile）"
fi
for f in "$@"; do
  [ -r "$f" ] || { info "読めません: $f"; continue; }
  if grep -nE "(>>?|tee( -a)?) *[^ ]*${LOG_BASENAME}" "$f" >/dev/null; then
    warn "$f で ${LOG_BASENAME} へのリダイレクト／tee があります → 原因候補2"
    grep -nE "(>>?|tee( -a)?) *[^ ]*${LOG_BASENAME}" "$f" | sed 's/^/        /'
  else
    info "$f（${LOG_BASENAME} へのリダイレクトなし）"
  fi
done

# -------------------------------------------------------------------------------------------
# 6. （任意）稼働中サーバーの実行時設定
# -------------------------------------------------------------------------------------------
if [ "$USE_CLI" -eq 1 ]; then
  hdr "6. 稼働中サーバーの実行時設定（jboss-cli.sh）"
  CLI="$JBOSS_HOME/bin/jboss-cli.sh"
  if [ -x "$CLI" ]; then
    "$CLI" --connect --commands="\
/subsystem=logging/periodic-rotating-file-handler=*:read-attribute(name=file),\
/subsystem=logging/size-rotating-file-handler=*:read-attribute(name=file),\
/subsystem=logging/periodic-size-rotating-file-handler=*:read-attribute(name=file),\
/subsystem=logging/file-handler=*:read-attribute(name=file),\
/subsystem=logging/logging-profile=*/periodic-rotating-file-handler=*:read-attribute(name=file),\
/subsystem=logging:read-attribute(name=use-deployment-logging-config),\
/deployment=*/subsystem=logging/configuration=*:read-resource(recursive=true,include-runtime=true)" \
      | sed 's/^/  /'
    info "最後の /deployment=*/subsystem=logging/configuration=* は EAP 7 系の実行時リソースです。handler に FILE 以外で server.log を指すものがあれば原因候補1です。"
  else
    info "jboss-cli.sh が見つかりません: $CLI"
  fi
fi

echo
if [ ! -s "$FLAG" ]; then
  echo "指摘なし。check-server-log-fd.sh の結果が異常なら、コンテナ外（別ホスト・運用手順）の rename を疑ってください。"
  exit 0
fi
echo "指摘あり。上の [指摘] を修正してください（対策は md の 16 章／Excel の 18_JBoss_対策と設定）。"
exit 1
