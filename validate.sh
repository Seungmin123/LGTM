#!/usr/bin/env bash
# 배포 전 설정 파일 검증 스크립트
# docker-compose.yml에 고정된 것과 동일한 이미지로 각 설정 파일의 문법·스키마를 검사한다.
# push 전에 로컬에서 실행: ./validate.sh
set -uo pipefail
cd "$(dirname "$0")"

FAIL=0

# compose에서 서비스 이미지 태그 추출 (검증 이미지가 실제 배포 이미지와 어긋나지 않도록)
image_of() {
  grep -A2 "^  $1:" docker-compose.yml | grep -oE 'image: *\S+' | head -1 | awk '{print $2}'
}

check() {
  local name="$1"; shift
  local out
  out=$("$@" 2>&1)
  # mimir 등 일부 바이너리는 설정 오류에도 exit 0을 반환하므로 출력의 error 문자열도 검사
  if [ $? -ne 0 ] || echo "$out" | grep -qiE "error (validating|loading|parsing)|unmarshal|failed to parse"; then
    echo "✘ $name"
    echo "$out" | grep -iE "error|unmarshal|failed" | head -5 | sed 's/^/    /'
    FAIL=1
  else
    echo "✔ $name"
  fi
}

MIMIR_IMG=$(image_of mimir)
LOKI_IMG=$(image_of loki)
TEMPO_IMG=$(image_of tempo)
PROM_IMG=$(image_of prometheus)
OTEL_IMG=$(image_of otel-collector)

echo "== 설정 검증 시작 =="

check "mimir ($MIMIR_IMG)" \
  docker run --rm -v "$PWD/mimir/config.yml:/etc/mimir/config.yml:ro" \
  "$MIMIR_IMG" -config.file=/etc/mimir/config.yml -modules

check "loki ($LOKI_IMG)" \
  docker run --rm -v "$PWD/loki/config.yml:/etc/loki/config.yml:ro" \
  "$LOKI_IMG" -config.file=/etc/loki/config.yml -verify-config

check "prometheus ($PROM_IMG)" \
  docker run --rm --entrypoint promtool -v "$PWD/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  "$PROM_IMG" check config --syntax-only /etc/prometheus/prometheus.yml

check "otel-collector ($OTEL_IMG)" \
  docker run --rm -v "$PWD/otel/collector-config.yaml:/etc/otelcol/config.yaml:ro" \
  "$OTEL_IMG" validate --config=/etc/otelcol/config.yaml

# tempo는 검증 서브커맨드가 없어 짧게 실행해서 파싱 단계 통과 여부를 본다
tempo_check() {
  local cid
  cid=$(docker run -d -v "$PWD/tempo/tempo.yaml:/etc/tempo.yaml:ro" "$TEMPO_IMG" -config.file=/etc/tempo.yaml 2>/dev/null)
  sleep 6
  local status logs
  status=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null)
  logs=$(docker logs "$cid" 2>&1)
  if echo "$logs" | grep -qiE "failed parsing config|unmarshal|field .* not found"; then
    echo "✘ tempo ($TEMPO_IMG) — 설정 파싱 실패"
    echo "$logs" | grep -iE "error|failed" | head -5 | sed 's/^/    /'
    FAIL=1
  elif [ "$status" = "running" ]; then
    echo "✔ tempo ($TEMPO_IMG)"
  elif echo "$logs" | grep -qiE "Access Denied|NoCredentialProviders|InvalidAccessKeyId|no such host"; then
    echo "✔ tempo ($TEMPO_IMG) — 설정 파싱 OK (S3 접근은 로컬에서 검증 불가, EC2에서 확인)"
  else
    echo "✘ tempo ($TEMPO_IMG)"
    echo "$logs" | grep -iE "error|failed" | head -5 | sed 's/^/    /'
    FAIL=1
  fi
  docker rm -f "$cid" >/dev/null 2>&1
}
tempo_check

# docker compose 자체 문법 검사
if docker compose config -q 2>/dev/null; then
  echo "✔ docker-compose.yml"
else
  echo "✘ docker-compose.yml"
  docker compose config 2>&1 | head -5 | sed 's/^/    /'
  FAIL=1
fi

echo "== 완료 =="
exit $FAIL
