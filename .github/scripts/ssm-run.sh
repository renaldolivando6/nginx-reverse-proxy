#!/usr/bin/env bash
# Jalankan skrip shell di server AWS lewat SSM (AWS-RunShellScript), tunggu
# selesai, cetak output, dan keluar dengan status skrip. Padanan tat-run.sh
# untuk server Tencent.
#
# Pemakaian: .github/scripts/ssm-run.sh <instance-id> <file-skrip> [timeout-detik]
# Butuh aws CLI (kredensial dari aws-actions/configure-aws-credentials) dan jq.
#
# Catatan: isi skrip tersimpan di riwayat Run Command SSM. Jangan kirim secret
# permanen lewat skrip ini (taruh manual di server).
set -euo pipefail

INSTANCE="${1:?Pemakaian: ssm-run.sh <instance-id> <file-skrip> [timeout-detik]}"
SCRIPT="${2:?Pemakaian: ssm-run.sh <instance-id> <file-skrip> [timeout-detik]}"
TIMEOUT="${3:-900}"

WRAPPED=$(mktemp)
PARAMS=$(mktemp)
trap 'rm -f "$WRAPPED" "$PARAMS"' EXIT

# Dibungkus supaya selalu dijalankan bash (skrip memakai array dan pipefail),
# apa pun shell yang dipakai agent SSM. Skrip ditulis ke file sementara, bukan
# lewat stdin, supaya perintah di dalamnya tidak ikut membaca sisa skrip.
# shellcheck disable=SC2016 # sengaja literal: baru dievaluasi di server, bukan di runner.
{
    echo 'SSM_SCRIPT=$(mktemp /tmp/ssm-XXXXXX.sh)'
    echo "cat > \"\$SSM_SCRIPT\" <<'SSM_SCRIPT_EOF'"
    cat "$SCRIPT"
    echo 'SSM_SCRIPT_EOF'
    echo 'bash "$SSM_SCRIPT"; SSM_RC=$?'
    echo 'rm -f "$SSM_SCRIPT"'
    echo 'exit $SSM_RC'
} > "$WRAPPED"

jq -n --rawfile cmd "$WRAPPED" --arg timeout "$TIMEOUT" \
    '{commands: [$cmd], executionTimeout: [$timeout]}' > "$PARAMS"

CMD_ID=$(aws ssm send-command \
    --document-name AWS-RunShellScript \
    --instance-ids "$INSTANCE" \
    --comment "${GITHUB_REPOSITORY:-manual} ${GITHUB_SHA:-}" \
    --parameters "file://$PARAMS" \
    --query Command.CommandId --output text)
echo "SSM command: $CMD_ID"

# Tunggu status akhir. `aws ssm wait command-executed` berhenti setelah +-100
# detik, terlalu pendek untuk pull image + terbit sertifikat.
DEADLINE=$((SECONDS + TIMEOUT + 120))
STATUS=Pending
while :; do
    sleep 5
    STATUS=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE" \
        --query Status --output text 2>/dev/null) || STATUS=Pending
    case "$STATUS" in
        Success | Failed | Cancelled | TimedOut) break ;;
    esac
    if [ "$SECONDS" -ge "$DEADLINE" ]; then
        echo "Berhenti menunggu setelah $TIMEOUT detik (status terakhir: $STATUS)"
        break
    fi
done

echo "----- output server -----"
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE" \
    --query StandardOutputContent --output text || true
ERR=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE" \
    --query StandardErrorContent --output text 2>/dev/null || true)
if [ -n "$ERR" ] && [ "$ERR" != None ]; then
    echo "----- stderr server -----"
    printf '%s\n' "$ERR"
fi
echo "-------------------------"
echo "SSM status: $STATUS"

if [ "$STATUS" != Success ]; then
    echo "::error::Perintah di server gagal ($STATUS). Lihat output di atas."
    exit 1
fi
