#!/usr/bin/env sh
# End-to-end check of the generators and the running servers.
#   ./etc/check.sh        (from the project root; needs Go >= 1.26, protoc, curl)
# 1. installs the generators, 2. generates + vets + builds, 3. starts two nodes,
# 4. calls every operation and compares the HTTP status code with the spec.
set -eu
cd "$(dirname "$0")/.."

step() { printf '\n== %s\n' "$*"; }

step "1/4 generators"
command -v protoc >/dev/null || { echo "protoc not found: https://protobuf.dev/installation/"; exit 1; }
make setup >/dev/null
go tool oapi-codegen -version 2>/dev/null | head -1 || true
protoc --version

step "2/4 generate, vet, build"
make build

step "3/4 start n1 (:18080/:15051) and n2 (:18081 -> n1)"
./bin/server -id n1 -http :18080 -grpc :15051 >/tmp/kvs-n1.log 2>&1 & P1=$!
./bin/server -id n2 -http :18081 -grpc :15052 -target localhost:15051 >/tmp/kvs-n2.log 2>&1 & P2=$!
trap 'kill $P1 $P2 2>/dev/null' EXIT
for i in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null localhost:18080/openapi.yaml && break; sleep 0.3; done

step "4/4 every operation"
RESULTS_FILE=check-results.txt ./etc/demo.sh \
  http://localhost:18080 http://localhost:18081
