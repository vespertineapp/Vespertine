# A Samba 4.19 test server for SMBLiveTests (see run.sh). Alpine 3.20 ships Samba 4.19.
FROM alpine:3.20
RUN apk add --no-cache samba-server samba-common-tools iproute2
COPY start.sh /start.sh
RUN chmod +x /start.sh
ENTRYPOINT ["/start.sh"]
