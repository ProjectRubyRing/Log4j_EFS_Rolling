#!/bin/sh
# ServerLogRotationRepro.java を、JBoss EAP 7.4 系と同じ jboss-logmanager 2.1 系で実行する。
#
#   使い方: ./run_repro.sh [出力ディレクトリ]
#     出力ディレクトリに EFS 上のパス（例: /mnt/efs/logs/repro）を渡すと EFS 上で再現できる。
#
#   必要なもの: Java 17 以上（単一ファイルのソース実行と record 構文を使うため）、curl
#   JBoss EAP 本体は不要。
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OUT_DIR="${1:-${SCRIPT_DIR}/repro-out}"
LIB_DIR="${SCRIPT_DIR}/lib"

# JBoss EAP 7.4 が同梱している系列に合わせる（EAP の実バージョンに合わせて変更可）
LOGMANAGER_VERSION="${LOGMANAGER_VERSION:-2.1.19.Final}"
WILDFLY_COMMON_VERSION="${WILDFLY_COMMON_VERSION:-1.5.4.Final}"

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

exec java -Dstdout.encoding=UTF-8 -cp "$CP" "${SCRIPT_DIR}/ServerLogRotationRepro.java" "$OUT_DIR"
