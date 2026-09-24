#!/bin/sh
# ServerLogRotationRepro.java（原因候補1〜4）を、JBoss EAP 8.1 と同じ jboss-logmanager で実行する。
#
#   使い方:
#     ./run_repro.sh [出力ディレクトリ]              … 原因候補1〜4（数秒で終わる）
#     ./run_repro.sh --reload4j [出力ディレクトリ]   … 原因候補1b：アプリ同梱 reload4j との共存（最大 70 秒）
#     出力ディレクトリに EFS 上のパス（例: /mnt/efs/logs/repro）を渡すと EFS 上で再現できる。
#
#   必要なもの: Java 17 以上（EAP 8.1 がサポートする JDK 17 / 21 で動作）、curl
#   JBoss EAP 本体は不要。
#
#   バージョンの根拠（2026-09-24 に Maven Central の POM で確認）:
#     JBoss EAP 8.1 → WildFly 35 → WildFly Core 27.0.x
#     WildFly Core 27.0.x の version.org.jboss.logmanager.jboss-logmanager = 2.1.19.Final
#                         version.org.wildfly.common                     = 1.7.0.Final
#   EAP 8.1 の製品版は同じバージョンに -redhat-NNNNN が付いたものです。実環境で
#     ls $JBOSS_HOME/modules/system/layers/base/org/jboss/logmanager/main/
#   を見て、異なる場合は LOGMANAGER_VERSION を合わせてください。
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MAIN=ServerLogRotationRepro.java
if [ "${1:-}" = "--reload4j" ]; then
  MAIN=MixedLibraryRepro.java
  shift
fi
OUT_DIR="${1:-${SCRIPT_DIR}/repro-out}"
LIB_DIR="${SCRIPT_DIR}/lib"

LOGMANAGER_VERSION="${LOGMANAGER_VERSION:-2.1.19.Final}"
WILDFLY_COMMON_VERSION="${WILDFLY_COMMON_VERSION:-1.7.0.Final}"
RELOAD4J_VERSION="${RELOAD4J_VERSION:-1.2.26}"

MIRRORS="https://repo1.maven.org/maven2 https://maven-central.storage-download.googleapis.com/maven2"

fetch() {
  # $1 = groupId のパス, $2 = artifactId, $3 = version
  jar="${LIB_DIR}/$2-$3.jar"
  [ -s "$jar" ] && return 0
  for m in $MIRRORS; do
    if curl -sSfL -o "$jar" "$m/$1/$2/$3/$2-$3.jar"; then
      return 0
    fi
  done
  echo "取得に失敗しました: $2-$3.jar" >&2
  rm -f "$jar"
  exit 1
}

mkdir -p "$LIB_DIR"
fetch org/jboss/logmanager jboss-logmanager "$LOGMANAGER_VERSION"
fetch org/wildfly/common   wildfly-common   "$WILDFLY_COMMON_VERSION"
CP="${LIB_DIR}/jboss-logmanager-${LOGMANAGER_VERSION}.jar:${LIB_DIR}/wildfly-common-${WILDFLY_COMMON_VERSION}.jar"
if [ "$MAIN" = MixedLibraryRepro.java ]; then
  fetch ch/qos/reload4j reload4j "$RELOAD4J_VERSION"
  CP="${CP}:${LIB_DIR}/reload4j-${RELOAD4J_VERSION}.jar"
fi

exec java -Dstdout.encoding=UTF-8 -cp "$CP" "${SCRIPT_DIR}/${MAIN}" "$OUT_DIR"
