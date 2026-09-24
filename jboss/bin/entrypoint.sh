#!/bin/sh
# entrypoint.sh（JBoss EAP コンテナ用）
#
#   server.log を「JBoss の FILE ハンドラだけが開き、JBoss だけが rename する」状態で起動する。
#
#   ★ やってはいけないこと（原因候補2）
#       exec standalone.sh >> "$JBOSS_LOG_DIR/server.log" 2>&1
#       standalone.sh 2>&1 | tee -a "$JBOSS_LOG_DIR/server.log"
#     シェルが開いた FD は JBoss の回転を知らないため、日付が変わると CONSOLE ハンドラの出力や
#     System.out が server.log.<前日> に書かれ続ける。stdout はそのまま ECS（awslogs/FireLens）へ渡す。
set -eu

JBOSS_HOME="${JBOSS_HOME:-/opt/jboss}"
EFS_LOG_ROOT="${EFS_LOG_ROOT:-/mnt/efs/logs}"

# ---- タスクID（ECS タスクメタデータ v4）とコンテナ名（front / back など）----------------------
if [ -n "${ECS_CONTAINER_METADATA_URI_V4:-}" ]; then
  TASK_JSON=$(curl -sf --max-time 3 "${ECS_CONTAINER_METADATA_URI_V4}/task" || true)
  TASK_ARN=$(printf '%s' "$TASK_JSON" | sed -n 's/.*"TaskARN"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -n "$TASK_ARN" ] && ECS_TASK_ID="${ECS_TASK_ID:-${TASK_ARN##*/}}"
  CONTAINER_JSON=$(curl -sf --max-time 3 "${ECS_CONTAINER_METADATA_URI_V4}" || true)
  CNAME=$(printf '%s' "$CONTAINER_JSON" | sed -n 's/.*"com\.amazonaws\.ecs\.container-name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -n "$CNAME" ] && CONTAINER_ROLE="${CONTAINER_ROLE:-$CNAME}"
fi
: "${ECS_TASK_ID:=$(hostname)-$$}"
: "${CONTAINER_ROLE:=jboss}"
export ECS_TASK_ID CONTAINER_ROLE

# ---- ログディレクトリ -----------------------------------------------------------------------
#   standalone.sh は JBOSS_LOG_DIR から起動時ログ（-Dorg.jboss.boot.log.file）の場所を決め、
#   -Djboss.server.log.dir から subsystem の FILE ハンドラの場所を決める。
#   2つを必ず同じディレクトリにする（食い違うと起動直後だけ別の server.log に書かれる）。
JBOSS_LOG_DIR="${EFS_LOG_ROOT}/${ECS_TASK_ID}/${CONTAINER_ROLE}"
export JBOSS_LOG_DIR
mkdir -p "$JBOSS_LOG_DIR"

# ---- タイムゾーン ---------------------------------------------------------------------------
#   periodic-rotating-file-handler の「日付またぎ」は JVM の既定タイムゾーンで判定される。
#   UTC のままだと回転は JST 09:00 になり、server.log.<前日> に JST 0〜9時のログが入る（原因候補4）。
TZ="${TZ:-Asia/Tokyo}"
export TZ
JAVA_OPTS="${JAVA_OPTS:-} -Duser.timezone=${TZ}"
export JAVA_OPTS

# ---- 起動（リダイレクトしない。exec で PID 1 にして SIGTERM を JBoss に届ける）------------------
exec "$JBOSS_HOME/bin/standalone.sh" \
  -b 0.0.0.0 \
  -Djboss.server.log.dir="$JBOSS_LOG_DIR" \
  "$@"
