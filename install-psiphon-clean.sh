#!/usr/bin/env bash
set -Eeuo pipefail

BIN_URL="https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64"
BIN="/usr/local/bin/psiphon-tunnel-core"
CONFIG_DIR="/etc/psiphon"
CONFIG="$CONFIG_DIR/config.json"
DATA_DIR="/var/lib/psiphon"
SERVICE="/etc/systemd/system/psiphon.service"
DB="/etc/x-ui/x-ui.db"

[[ $EUID -eq 0 ]] || { echo 'Run as root'; exit 1; }
[[ "$(uname -m)" == "x86_64" ]] || { echo 'Only x86_64 is supported'; exit 1; }
command -v jq >/dev/null || { apt-get update; apt-get install -y jq; }
command -v sqlite3 >/dev/null || { apt-get update; apt-get install -y sqlite3; }
[[ -x /usr/local/x-ui/bin/xray-linux-amd64 ]] || { echo 'Xray binary not found: /usr/local/x-ui/bin/xray-linux-amd64'; exit 1; }
[[ -f "$DB" ]] || { echo 'X-UI database not found: /etc/x-ui/x-ui.db'; exit 1; }

install -d -m 755 "$CONFIG_DIR" "$DATA_DIR"
curl -fL --retry 3 --connect-timeout 15 "$BIN_URL" -o "$BIN"
chmod 755 "$BIN"

cat > "$CONFIG" <<'JSON'
{
  "ClientVersion": "486",
  "PropagationChannelId": "92AACC5BABE0944C",
  "SponsorId": "1BC527D3D09985CF",
  "RemoteServerListURLs": [{"URL":"aHR0cHM6Ly9zMy5hbWF6b25hd3MuY29tL3BzaXBob24vd2ViL21qcjQtcDIzci1wdXdsL3NlcnZlcl9saXN0X2NvbXByZXNzZWQ=","OnlyAfterAttempts":0,"SkipVerify":false}],
  "ObfuscatedServerListRootURLs": [{"URL":"aHR0cHM6Ly9zMy5hbWF6b25hd3MuY29tL3BzaXBob24vd2ViL21qcjQtcDIzci1wdXdsL29zbA==","OnlyAfterAttempts":0,"SkipVerify":false}],
  "RemoteServerListSignaturePublicKey": "MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAt7Ls+/39r+T6zNW7GiVpJfzq/xvL9SBH5rIFnk0RXYEYavax3WS6HOD35eTAqn8AniOwiH+DOkvgSKF2caqk/y1dfq47Pdymtwzp9ikpB1C5OfAysXzBiwVJlCdajBKvBZDerV1cMvRzCKvKwRmvDmHgphQQ7WfXIGbRbmmk6opMBh3roE42KcotLFtqp0RRwLtcBRNtCdsrVsjiI1Lqz/lH+T61sGjSjQ3CHMuZYSQJZo/KrvzgQXpkaCTdbObxHqb6/+i1qaVOfEsvjoiyzTxJADvSytVtcTjijhPEV6XskJVHE1Zgl+7rATr/pDQkw6DPCNBS1+Y6fy7GstZALQXwEDN/qhQI9kWkHijT8ns+i1vGg00Mk/6J75arLhqcodWsdeG/M/moWgqQAnlZAGVtJI1OgeF5fsPpXu4kctOfuZlGjVZXQNW34aOzm8r8S0eVZitPlbhcPiR4gT/aSMz/wd8lZlzZYsje/Jr8u/YtlwjjreZrGRmG8KMOzukV3lLmMppXFMvl4bxv6YFEmIuTsOhbLTwFgh7KYNjodLj/LsqRVfwz31PgWQFTEPICV7GCvgVlPRxnofqKSjgTWI4mxDhBpVcATvaoBl1L/6WLbFvBsoAUBItWwctO2xalKxF5szhGm8lccoc5MZr8kfE0uxMgsxz4er68iCID+rsCAQM=",
  "ServerEntrySignaturePublicKey": "sHuUVTWaRyh5pZwy4UguSgkwmBe0EHtJJkoF5WrxmvA=",
  "ExchangeObfuscationKey": "DpXzloJk1Hw6aSzmKKky0xcahsEHubch81Mi6K0XMlU=",
  "LocalSocksProxyPort": 10808,
  "DisableLocalHTTPProxy": true,
  "EgressRegion": "US"
}
JSON
chmod 600 "$CONFIG"
jq -e . "$CONFIG" >/dev/null

cat > "$SERVICE" <<'UNIT'
[Unit]
Description=Psiphon Tunnel Core local SOCKS5 proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/psiphon-tunnel-core -config /etc/psiphon/config.json -dataRootDirectory /var/lib/psiphon -listenInterface lo -formatNotices
Restart=always
RestartSec=5
TimeoutStopSec=15
User=root
Group=root
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now psiphon.service
sleep 8
ss -lnt '( sport = :10808 )' | grep -q 10808 || { journalctl -u psiphon -n 40 --no-pager; exit 1; }

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="$DB.before-psiphon-$STAMP"
sqlite3 "$DB" ".backup '$BACKUP'"
sqlite3 -readonly "$DB" "SELECT value FROM settings WHERE key='xrayTemplateConfig';" > /tmp/xray-template-clean.json
jq -e . /tmp/xray-template-clean.json >/dev/null

jq '
  if any(.outbounds[]?; .tag == "psiphon-socks") then . else
    .outbounds += [{"protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":10808}]},"tag":"psiphon-socks"}]
  end
  | if any(.routing.rules[]?; .outboundTag == "psiphon-socks") then . else
    .routing.rules = (.routing.rules[:1] + [{"type":"field","domain":["domain:gemini.google.com","domain:aistudio.google.com","domain:ai.google.dev","domain:makersuite.google.com","domain:generativelanguage.googleapis.com","domain:generativelanguage-pa.googleapis.com","domain:alkalimakersuite-pa.clients6.google.com","domain:deepmind.google"],"outboundTag":"psiphon-socks"}] + .routing.rules[1:])
  end
' /tmp/xray-template-clean.json > /tmp/xray-template-clean-after.json

sqlite3 "$DB" "BEGIN IMMEDIATE; UPDATE settings SET value=CAST(readfile('/tmp/xray-template-clean-after.json') AS TEXT) WHERE key='xrayTemplateConfig'; COMMIT;"
systemctl restart x-ui
sleep 8

jq -e '.outbounds[] | select(.tag == "psiphon-socks")' /usr/local/x-ui/bin/config.json >/dev/null
/usr/local/x-ui/bin/xray-linux-amd64 run -test -config /usr/local/x-ui/bin/config.json >/tmp/xray-clean-test.log 2>&1
grep -q 'Configuration OK' /tmp/xray-clean-test.log

echo "OK: Psiphon installed; SOCKS5=127.0.0.1:10808; X-UI updated"
echo "Backup: $BACKUP"
