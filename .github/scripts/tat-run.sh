#!/usr/bin/env bash
# Jalankan skrip shell di server Tencent (Lighthouse/CVM) lewat TAT
# (TencentCloud Automation Tools, tab "Run commands" di Lighthouse), tunggu
# selesai, cetak output, dan keluar dengan status skrip. Padanan SSM send-command.
#
# Pemakaian: .github/scripts/tat-run.sh <file-skrip> [timeout-detik]
# Env wajib: TENCENTCLOUD_SECRET_ID, TENCENTCLOUD_SECRET_KEY, TENCENT_REGION,
#            TENCENT_INSTANCE_ID (mis. lhins-xxxx). Butuh tccli dan jq.
#
# Catatan: isi skrip tersimpan di riwayat invocation TAT. Jangan kirim secret
# permanen lewat skrip ini (.env production ditaruh manual di server).
set -euo pipefail

SCRIPT="${1:?Pemakaian: tat-run.sh <file-skrip> [timeout-detik]}"
TIMEOUT="${2:-900}"
: "${TENCENTCLOUD_SECRET_ID:?}" "${TENCENTCLOUD_SECRET_KEY:?}" "${TENCENT_REGION:?}" "${TENCENT_INSTANCE_ID:?}"

# Dibungkus supaya selalu dijalankan bash (skrip memakai `set -o pipefail`),
# apa pun shell yang dipakai agent TAT. Skrip ditulis ke file sementara, bukan
# lewat stdin, supaya perintah di dalamnya tidak ikut membaca sisa skrip.
WRAPPED=$(mktemp)
# shellcheck disable=SC2016 # sengaja literal: baru dievaluasi di server, bukan di runner.
{
    echo 'TAT_SCRIPT=$(mktemp /tmp/tat-XXXXXX.sh)'
    echo "cat > \"\$TAT_SCRIPT\" <<'TAT_SCRIPT_EOF'"
    cat "$SCRIPT"
    echo 'TAT_SCRIPT_EOF'
    echo 'bash "$TAT_SCRIPT"; TAT_RC=$?'
    echo 'rm -f "$TAT_SCRIPT"'
    echo 'exit $TAT_RC'
} > "$WRAPPED"

CONTENT=$(base64 -w 0 "$WRAPPED")
rm -f "$WRAPPED"

# Batas konten TAT 64 KB (setelah base64).
if [ "${#CONTENT}" -gt 65536 ]; then
    echo "::error::Skrip terlalu besar untuk TAT (${#CONTENT} byte setelah base64, maks. 65536)."
    exit 1
fi

tccli configure set secretId "$TENCENTCLOUD_SECRET_ID" secretKey "$TENCENTCLOUD_SECRET_KEY" region "$TENCENT_REGION" >/dev/null

INVOCATION=$(tccli tat RunCommand \
    --region "$TENCENT_REGION" \
    --CommandType SHELL \
    --Content "$CONTENT" \
    --InstanceIds "[\"$TENCENT_INSTANCE_ID\"]" \
    --Timeout "$TIMEOUT" \
    --Username root \
    --WorkingDirectory /root \
    --SaveCommand False | jq -r '.InvocationId')

echo "TAT invocation: $INVOCATION"

# Tunggu sampai selesai. Status antara: PENDING, RUNNING (dan DELIVERING).
for _ in $(seq 1 $((TIMEOUT / 5 + 24))); do
    sleep 5
    STATUS=$(tccli tat DescribeInvocations --region "$TENCENT_REGION" --InvocationIds "[\"$INVOCATION\"]" \
        | jq -r '.InvocationSet[0].InvocationStatus')

    case "$STATUS" in
        PENDING | RUNNING | DELIVERING) continue ;;
        *) break ;;
    esac
done

TASK=$(tccli tat DescribeInvocations --region "$TENCENT_REGION" --InvocationIds "[\"$INVOCATION\"]" \
    | jq -r '.InvocationSet[0].InvocationTaskBasicInfoSet[0].InvocationTaskId')
RESULT=$(tccli tat DescribeInvocationTasks --region "$TENCENT_REGION" --InvocationTaskIds "[\"$TASK\"]" --HideOutput False)

echo "----- output server -----"
echo "$RESULT" | jq -r '.InvocationTaskSet[0].TaskResult.Output // ""' | base64 -d || true
echo "-------------------------"

TASK_STATUS=$(echo "$RESULT" | jq -r '.InvocationTaskSet[0].TaskStatus')
EXIT_CODE=$(echo "$RESULT" | jq -r '.InvocationTaskSet[0].TaskResult.ExitCode')
echo "TAT status: $TASK_STATUS, exit code: $EXIT_CODE"

if [ "$TASK_STATUS" != "SUCCESS" ] || [ "$EXIT_CODE" != "0" ]; then
    echo "::error::Perintah di server gagal ($TASK_STATUS, exit $EXIT_CODE). Lihat output di atas."
    exit 1
fi
