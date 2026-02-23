FROM alpine:latest

RUN apk add --no-cache openssl

COPY setup.sh /setup.sh
RUN chmod +x /setup.sh

WORKDIR /config

ENTRYPOINT ["/setup.sh"]
