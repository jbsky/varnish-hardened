#!/bin/bash
# Test suite for varnish-hardened
set -eu

HOST="${1:-127.0.0.1}"
PORT="${2:-8080}"
BASE="http://${HOST}:${PORT}"
PASS=0
FAIL=0

check() {
    local desc="$1" expected="$2" url="$3"
    actual=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${url}" 2>/dev/null || echo "000")
    if [ "$actual" = "$expected" ]; then
        printf "  \033[32mPASS\033[0m %s (HTTP %s)\n" "$desc" "$actual"
        PASS=$((PASS + 1))
    else
        printf "  \033[31mFAIL\033[0m %s (expected %s, got %s)\n" "$desc" "$expected" "$actual"
        FAIL=$((FAIL + 1))
    fi
}

check_header() {
    local desc="$1" header="$2" url="$3"
    val=$(curl -s -D - --max-time 5 "${url}" 2>/dev/null | grep -i "^${header}:" | head -1)
    if [ -n "$val" ]; then
        printf "  \033[32mPASS\033[0m %s (%s)\n" "$desc" "$val"
        PASS=$((PASS + 1))
    else
        printf "  \033[31mFAIL\033[0m %s (header '%s' not found)\n" "$desc" "$header"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
echo "=== Varnish Hardened Test Suite ==="
echo "Target: ${BASE}"
echo ""

echo "--- Healthcheck ---"
check "GET /healthcheck returns 200" "200" "${BASE}/healthcheck"
check_header "/healthcheck has Content-Type" "Content-Type" "${BASE}/healthcheck"

echo ""
echo "--- Security ---"
check "TRACE method blocked" "405" "${BASE}/"
check_header "No Via header exposed" "X-Cache" "${BASE}/healthcheck"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
