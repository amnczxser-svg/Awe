FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    openssh-server \
    openssl \
    ca-certificates \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/* \
  && ssh-keygen -A \
  && mkdir -p /run/sshd /app

WORKDIR /app

COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

EXPOSE 8080 2222

CMD ["/app/start.sh"]
