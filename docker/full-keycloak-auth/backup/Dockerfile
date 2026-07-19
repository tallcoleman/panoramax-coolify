FROM alpine:3.20
RUN apk add --no-cache postgresql16-client rclone restic ca-certificates tzdata curl gettext \
 && curl -fsSL -o /usr/local/bin/supercronic \
      https://github.com/aptible/supercronic/releases/download/v0.2.33/supercronic-linux-amd64 \
 && chmod +x /usr/local/bin/supercronic
COPY *.sh /usr/local/bin/
COPY crontab.template /etc/crontab.template
RUN chmod +x /usr/local/bin/*.sh
CMD ["entrypoint.sh"]
