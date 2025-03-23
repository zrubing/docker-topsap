FROM debian:buster-slim

WORKDIR /home/work

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

ENV SERVER_ADDRESS=""
ENV USER_NAME=""
ENV PASSWORD=""

COPY TopSAP-3.5.2.36.2-x86_64.deb .
COPY TopSAP-3.5.2.36.2-aarch64.deb .

RUN export DEBIAN_FRONTEND=noninteractive && \
  ln -fs /usr/share/zoneinfo/Asia /etc/localtime && \
  # if [ "${BUILD_ENV}" = "local" ]; then sed -i s/deb.debian.org/mirrors.aliyun.com/ /etc/apt/sources.list; fi &&\
  apt-get update && apt-get -y --no-install-suggests --no-install-recommends install \
    tzdata sudo curl dante-server iproute2 ca-certificates \
    iptables psmisc cron \
    wget unzip python3 python3-pip build-essential cmake \
    python3-dev ffmpeg libsm6 libxext6  coreutils \
    openssh-server xz-utils &&\
  dpkg-reconfigure --frontend noninteractive tzdata && \
  # 解决TopSap检测到Debian系统无法安装的问题，可以看这篇文章：https://blog.d77.xyz/archives/649aab5b.html
  echo Ubuntu >> /etc/issue && \
   # 根据架构安装对应的 TopSAP
  if [ "$(uname -m)" = "x86_64" ]; then dpkg -i TopSAP-3.5.2.36.2-x86_64.deb; else dpkg -i TopSAP-3.5.2.36.2-aarch64.deb; fi && \
  rm -r TopSAP-3.5.2.36.2-x86_64.deb TopSAP-3.5.2.36.2-aarch64.deb && \
  apt-get install -y expect && \
  rm -rf /var/lib/apt/lists/*

# Install s6-overlay
ADD https://github.com/just-containers/s6-overlay/releases/download/v3.1.6.2/s6-overlay-noarch.tar.xz /tmp
RUN tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz
ADD https://github.com/just-containers/s6-overlay/releases/download/v3.1.6.2/s6-overlay-x86_64.tar.xz /tmp
RUN tar -C / -Jxpf /tmp/s6-overlay-x86_64.tar.xz

# Define sshd as a long running s6 service
COPY <<EOF /etc/s6-overlay/s6-rc.d/sshd/type
longrun
EOF

COPY <<EOF /etc/s6-overlay/s6-rc.d/autologin/type
longrun
EOF

COPY <<EOF /etc/s6-overlay/s6-rc.d/topsap_client/type
longrun
EOF




# Define entrypoint for sshd
# Create sshd's required directory
# Daemon applications tend to log to stderr, so redirect it to stdout
# Start sshd in the foreground
COPY --chmod=700 <<EOF /etc/s6-overlay/s6-rc.d/sshd/run
#!/bin/sh
mkdir -p /var/run/sshd
/usr/sbin/sshd -D -e
EOF

COPY --chmod=700 <<EOF /etc/s6-overlay/s6-rc.d/autologin/run
#!/bin/sh
cd /home/work/Autologin
exec 2>&1
exec python3 app.py
EOF

COPY --chmod=700 <<EOF /etc/s6-overlay/s6-rc.d/topsap_client/run
#!/bin/sh
exec 2>&1
cd /home/work/TopSap_Client
exec python3 top.py
EOF

# Register sshd as a service for s6 to manage
RUN touch /etc/s6-overlay/s6-rc.d/user/contents.d/sshd

RUN touch /etc/s6-overlay/s6-rc.d/user/contents.d/autologin
RUN touch /etc/s6-overlay/s6-rc.d/user/contents.d/topsap_client

# Copy my ssh public keys to the container
ADD https://github.com/zrubing.keys /root/.ssh/authorized_keys


ENV TOPSAP_CLIENT_VER="de1d7e61c466414854890e09115b4e49d3bdf6ae"

RUN wget https://github.com/Sajor-X/AutoLogin/archive/refs/heads/main.tar.gz -O Autologin-main.tar.gz \
    && wget https://github.com/zrubing/TopSAP_Client/archive/${TOPSAP_CLIENT_VER}.tar.gz -O TopSap_Client-main.tar.gz \
    && pip3 install wheel setuptools \
    && pip3 install --upgrade pip \
    && pip3 install opencv-python \
    && mkdir TopSap_Client && tar -xvzf TopSap_Client-main.tar.gz -C TopSap_Client --strip-components=1  \
    && mkdir Autologin && tar -xvzf Autologin-main.tar.gz -C Autologin --strip-components=1


RUN (cd TopSap_Client && pip3 install -r requirements.txt)

RUN (ls -alh && cd Autologin && pip3 install -r requirements.txt)

COPY start.sh .
COPY danted.conf /etc
COPY expect.exp .

ENTRYPOINT ["/init"]
CMD chmod +x start.sh && /home/work/start.sh
