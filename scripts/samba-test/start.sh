#!/bin/sh
# Inside the container: one Samba 4.19 server set up as $MODE (see run.sh), for SMBLiveTests and the recordings.
# SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
set -e
adduser -D -H listener 2>/dev/null || true
printf 'Tr0ub4dor&3 \303\251\nTr0ub4dor&3 \303\251\n' | smbpasswd -a -s listener >/dev/null
mkdir -p "/srv/music/Music/Ilse Brandt/Nocturnes" /srv/archive
printf 'hello\n' > "/srv/music/Music/Ilse Brandt/Nocturnes/note.txt"
[ -f /srv/music/Music/random.bin ] || head -c 3000000 /dev/urandom > /srv/music/Music/random.bin
[ -f /srv/music/Music/big.bin ] || head -c 67108864 /dev/urandom > /srv/music/Music/big.bin
chmod -R a+rX /srv
G="server signing = mandatory"; S=""; MIN=SMB2_02; MAX=SMB3_11; GUEST="map to guest = Never"; GOK="guest ok = no"; ALG=""
case "$MODE" in
  smb202) MAX=SMB2_02 ;;
  smb210) MIN=SMB2_10; MAX=SMB2_10 ;;
  smb302) MIN=SMB3_02; MAX=SMB3_02 ;;
  smb311) MIN=SMB3_11 ;;
  smb311gcm) MIN=SMB3_11; G="server smb encrypt = required" ;;
  smb311ccm) MIN=SMB3_11; S="smb encrypt = required"; ALG="server smb3 encryption algorithms = aes-128-ccm" ;;
  smb302ccm) MIN=SMB3_02; MAX=SMB3_02; G="server smb encrypt = required" ;;
  smb311gcm256) MIN=SMB3_11; G="server smb encrypt = required"; ALG="server smb3 encryption algorithms = aes-256-gcm" ;;
  smb311ccm256) MIN=SMB3_11; G="server smb encrypt = required"; ALG="server smb3 encryption algorithms = aes-256-ccm" ;;
  smb311guest) MIN=SMB3_11; G=""; GUEST="map to guest = Bad User"; GOK="guest ok = yes" ;;
  smb311nobody) MIN=SMB3_11; G=""; GOK="guest ok = yes" ;;
  *) echo "unknown mode $MODE"; exit 2 ;;
esac
cat > /etc/samba/smb.conf <<CONF
[global]
  server role = standalone server
  workgroup = WORKGROUP
  server min protocol = $MIN
  server max protocol = $MAX
  $G
  $ALG
  $GUEST
  disable netbios = yes
  smb ports = 445
  log level = 1
  load printers = no
  printing = bsd
  printcap name = /dev/null
[music]
  path = /srv/music
  read only = yes
  $GOK
  $S
[archive]
  path = /srv/archive
  read only = yes
  comment = Old rips
[hidden$]
  path = /srv/archive
  read only = yes
CONF
if [ -n "$DELAY" ]; then tc qdisc add dev eth0 root netem limit 100000 delay ${DELAY}ms ${RATE:+rate $RATE} || echo "netem failed"; fi
exec smbd --foreground --no-process-group --debug-stdout
