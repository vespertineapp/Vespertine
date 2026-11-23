#!/bin/sh
# Starts a Samba 4.19 test server (Alpine 3.20) for SMBLiveTests on 127.0.0.1:PORT (default 4450), set up as MODE:
#   smb202 smb210 smb302 smb311          signed, one version each (account "listener", the test password)
#   smb311gcm smb302ccm                  the whole session encrypted (AES-128-GCM / AES-128-CCM)
#   smb311ccm                            one share asks for encryption (AES-128-CCM)
#   smb311gcm256 smb311ccm256            encrypted, the server taking only AES-256-GCM / AES-256-CCM
#   smb311guest smb311nobody             guests by name / with no name
# DELAY=50 adds 50 ms to every packet the server sends (netem), RATE=20mbit caps its rate: for VESPERTINE_SMB_BENCH.
# Shares: music (Music/Ilse Brandt/Nocturnes/note.txt, Music/random.bin, Music/big.bin), archive, and the hidden hidden$.
#   scripts/samba-test/run.sh smb311
#   VESPERTINE_SMB="127.0.0.1:4450/music/listener/Tr0ub4dor&3 é" swift test --package-path Packages/VespertineRemoteKit --filter SMBLiveTests
# The made-up account and password are the recordings' own (SMBReplayTests); nothing here is a real credential.
set -e
cd "$(dirname "$0")"
MODE=$1; PORT=${2:-4450}
docker build -q -t vt-samba . >/dev/null
docker rm -f vt-samba >/dev/null 2>&1 || true
docker run -d --name vt-samba --cap-add NET_ADMIN -e DELAY="$DELAY" -e RATE="$RATE" -e MODE="$MODE" -p 127.0.0.1:$PORT:445 -v vt-samba-data:/srv vt-samba >/dev/null
for i in $(seq 1 30); do nc -z 127.0.0.1 $PORT 2>/dev/null && sleep 1 && exit 0; sleep 0.5; done
docker logs vt-samba | tail; exit 1
