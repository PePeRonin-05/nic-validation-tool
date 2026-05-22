#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

START=$(date +%s)

# ── Usage ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'

NIC Validation Tool
===================
Usage:
  ./run.sh <test> <host> <server-port> <client-port> [<server-port> <client-port> ...] <duration-sec>

  Pairs are positional — list all srv/cli pairs before the duration.
  Duration is always the last argument.

Examples:
  # Single NIC pair
  ./run.sh iperf 172.28.165.63 enp241s0f0np0 enp241s0f1np1 43200
  ./run.sh rdma  172.28.165.63 enp241s0f0np0 enp241s0f1np1 43200

  # Two NIC pairs simultaneously (same host)
  ./run.sh rdma  172.28.164.198 ens121f0np0 ens121f1np1 ens120f0np0 ens120f1np1 43200
  ./run.sh iperf 172.28.164.198 ens121f0np0 ens121f1np1 ens120f0np0 ens120f1np1 43200

  # Both tests sequentially (duration split in half each)
  ./run.sh all   172.28.164.198 ens121f0np0 ens121f1np1 ens120f0np0 ens120f1np1 86400

Tests:
  iperf  — iperf3 loopback (bidirectional throughput)
  rdma   — RDMA loopback (ib_read_bw + ib_write_bw simultaneously)
  all    — iperf first, then rdma sequentially

EOF
  exit 1
}

# ── Parse arguments ────────────────────────────────────────────────────────────
[ $# -ge 5 ] || { echo "ERROR: too few arguments"; usage; }

TEST="$1"; HOST="$2"
shift 2

ARGS=("$@")
COUNT=${#ARGS[@]}

# After test+host: [srv cli]+ duration — must be odd and ≥ 3
if (( COUNT < 3 || COUNT % 2 == 0 )); then
  echo "ERROR: expected one or more <server-port> <client-port> pairs followed by <duration-sec>"
  usage
fi

DURATION="${ARGS[$((COUNT-1))]}"

case "$TEST" in
  iperf|rdma|all) ;;
  *) echo "ERROR: unknown test type '$TEST'"; usage ;;
esac

# ── Build pairs ────────────────────────────────────────────────────────────────
PAIRS_YAML=""
HEADER_PAIRS=""
i=0
while (( i < COUNT - 1 )); do
  SRV="${ARGS[$i]}"
  CLI="${ARGS[$((i+1))]}"
  PAIRS_YAML+="            - { server_port: ${SRV}, client_port: ${CLI} }"$'\n'
  HEADER_PAIRS+="               ${SRV}  ↔  ${CLI}"$'\n'
  i=$(( i + 2 ))
done

NPAIRS=$(( (COUNT - 1) / 2 ))

# ── Duration helpers ───────────────────────────────────────────────────────────
fmt_duration() {
  local s=$1
  local h=$(( s / 3600 ))
  local m=$(( (s % 3600) / 60 ))
  local r=$(( s % 60 ))
  if (( h > 0 )); then
    echo "${s}s (${h}h ${m}m)"
  else
    echo "${s}s (${m}m ${r}s)"
  fi
}

# ── Temp inventory files ───────────────────────────────────────────────────────
TMPINV_IPERF=$(mktemp /tmp/nic_inv_iperf_XXXXXX.yml)
TMPINV_RDMA=$(mktemp /tmp/nic_inv_rdma_XXXXXX.yml)
TMPINV_ALL=$(mktemp /tmp/nic_inv_all_XXXXXX.yml)

cleanup_tmp() { rm -f "$TMPINV_IPERF" "$TMPINV_RDMA" "$TMPINV_ALL"; }
trap cleanup_tmp EXIT

cat > "$TMPINV_IPERF" <<EOF
all:
  children:
    iperf_loopback:
      vars:
        test_type: loopback
        log_subdir: iperf_loopback
      hosts:
        nic-loopback:
          ansible_host: ${HOST}
          loopback_pairs:
${PAIRS_YAML}
EOF

cat > "$TMPINV_RDMA" <<EOF
all:
  children:
    rdma_loopback:
      vars:
        test_type: rdma_loopback
        log_subdir: rdma_loopback
      hosts:
        nic-rdma:
          ansible_host: ${HOST}
          loopback_pairs:
${PAIRS_YAML}
EOF

cat > "$TMPINV_ALL" <<EOF
all:
  children:
    nic_all:
      vars:
        test_type: all
        log_subdir: all
        log_subdirs:
          - iperf
          - rdma
          - iface_status
          - pci_logs
      hosts:
        nic-all:
          ansible_host: ${HOST}
          loopback_pairs:
${PAIRS_YAML}
EOF

# ── Header ────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  NIC Validation"
echo "  Host:        ${HOST}"
if (( NPAIRS == 1 )); then
  SRV="${ARGS[0]}"; CLI="${ARGS[1]}"
  echo "  Ports:       ${SRV}  ↔  ${CLI}"
else
  echo "  Pairs (${NPAIRS}):"
  echo -n "$HEADER_PAIRS"
fi
case "$TEST" in
  iperf)
    echo "  Test:        iperf3 loopback"
    echo "  Duration:    $(fmt_duration "$DURATION")"
    ;;
  rdma)
    echo "  Test:        RDMA loopback (ib_read_bw + ib_write_bw)"
    echo "  Duration:    $(fmt_duration "$DURATION")"
    ;;
  all)
    IPERF_DURATION=$(( DURATION / 2 ))
    RDMA_DURATION=$(( DURATION / 2 ))
    echo "  Test:        iperf3 + RDMA sequentially"
    echo "  Duration:    ${DURATION}s total → iperf ${IPERF_DURATION}s + rdma ${RDMA_DURATION}s"
    ;;
esac
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

RC_IPERF=0
RC_RDMA=0

# ── Execute ───────────────────────────────────────────────────────────────────
case "$TEST" in

  all)
    ansible-playbook \
      -i "${SCRIPT_DIR}/inventory/" -i "$TMPINV_ALL" \
      site_all.yml \
      -e "iperf_time=${IPERF_DURATION}" \
      -e "rdma_duration=${RDMA_DURATION}" \
      -e "local_log_dir=${SCRIPT_DIR}/local_logs/all_${DURATION}s" || RC_IPERF=$?
    RC_RDMA=$RC_IPERF
    ;;

  iperf)
    ansible-playbook \
      -i "${SCRIPT_DIR}/inventory/" -i "$TMPINV_IPERF" \
      site_loopback.yml \
      -e "iperf_time=${DURATION}" \
      -e "local_log_dir=${SCRIPT_DIR}/local_logs/iperf_${DURATION}s" || RC_IPERF=$?
    ;;

  rdma)
    ansible-playbook \
      -i "${SCRIPT_DIR}/inventory/" -i "$TMPINV_RDMA" \
      site_rdma_loopback.yml \
      -e "rdma_duration=${DURATION}" \
      -e "local_log_dir=${SCRIPT_DIR}/local_logs/rdma_${DURATION}s" || RC_RDMA=$?
    ;;

esac

# ── Elapsed time ──────────────────────────────────────────────────────────────
END=$(date +%s)
ELAPSED=$(( END - START ))
ELAPSED_M=$(( ELAPSED / 60 ))
ELAPSED_S=$(( ELAPSED % 60 ))

# ── Final status ──────────────────────────────────────────────────────────────
echo ""
if [[ $RC_IPERF -ne 0 || $RC_RDMA -ne 0 ]]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ❌  TEST FAILED"
  [[ $RC_IPERF -ne 0 ]] && echo "     iperf3 exit code: $RC_IPERF"
  [[ $RC_RDMA  -ne 0 ]] && echo "     RDMA   exit code: $RC_RDMA"
  echo "  Total time: ${ELAPSED_M}m ${ELAPSED_S}s"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅  ALL TESTS PASSED"
echo "  Total time: ${ELAPSED_M}m ${ELAPSED_S}s"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
exit 0
