FROM debian:bullseye-slim

WORKDIR /home/work

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    SERVER_ADDRESS="" \
    USER_NAME="" \
    PASSWORD=""

ARG TZ=Asia/Shanghai
ARG S6_OVERLAY_VERSION=3.1.6.2

# TopSAP deb
COPY TopSAP-3.5.2.36.2-x86_64.deb /home/work/
COPY TopSAP-3.5.2.36.2-aarch64.deb /home/work/

# 依赖安装 + 禁止 build 时启动服务(避免 cron/sshd 安装脚本失败)
RUN set -eux; \
    echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/50no-sandbox; \
    \
    # 禁止在镜像构建阶段启动/重启服务（rootless 下常见 dpkg 配置失败来源）
    printf '%s\n' '#!/bin/sh' 'exit 101' > /usr/sbin/policy-rc.d; \
    chmod +x /usr/sbin/policy-rc.d; \
    \
    export DEBIAN_FRONTEND=noninteractive; \
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime; \
    echo "${TZ}" > /etc/timezone; \
    \
    # 修复 rootless 容器权限问题：预创建组和绕过 dpkg-statoverride/chgrp
    touch /etc/shadow /etc/gshadow /etc/passwd /etc/group; \
    chmod 640 /etc/shadow /etc/gshadow; \
    chown root:shadow /etc/shadow /etc/gshadow; \
    chmod 644 /etc/passwd /etc/group; \
    chown root:root /etc/passwd /etc/group; \
    # 预创建 cron 和 openssh 需要的组
    echo 'crontab:x:101:' >> /etc/group; \
    echo 'crontab:!::' >> /etc/gshadow; \
    echo 'ssh:x:102:' >> /etc/group; \
    echo 'ssh:!::' >> /etc/gshadow; \
    # 创建 statoverride 钩子，绕过 dpkg-statoverride
    printf '%s\n' '#!/bin/sh' 'exit 0' > /usr/sbin/dpkg-statoverride; \
    chmod +x /usr/sbin/dpkg-statoverride; \
    # 创建 chgrp/chown 钩子
    printf '%s\n' '#!/bin/sh' 'exit 0' > /usr/bin/chgrp; \
    chmod +x /usr/bin/chgrp; \
    printf '%s\n' '#!/bin/sh' 'exit 0' > /usr/bin/chown; \
    chmod +x /usr/bin/chown; \
    # 创建 useradd 钩子，预创建 sshd 用户
    printf '%s\n' '#!/bin/sh' 'exit 0' > /usr/sbin/useradd; \
    chmod +x /usr/sbin/useradd; \
    echo 'sshd:x:101:65534::/run/sshd:/usr/sbin/nologin' >> /etc/passwd; \
    echo 'sshd:*:18999:0:99999:7:::' >> /etc/shadow; \
    \
    # 预先配置 fontconfig，避免配置失败
    mkdir -p /var/cache/fontconfig; \
    mkdir -p /etc/fonts; \
    \
    apt-get update; \
    # 先修复可能存在的依赖问题
    apt-get -y --fix-broken install || true; \
    # 分步安装：先装基础包
    apt-get -y --no-install-suggests --no-install-recommends install \
        ca-certificates curl wget unzip \
        python3 python3-pip python3-dev \
        build-essential cmake \
        libsm6 libxext6 coreutils xz-utils \
        tzdata iproute2 psmisc expect \
        sudo dante-server iptables; \
    # 再装 ffmpeg 相关（可能有依赖问题，单独处理）
    apt-get -y --no-install-suggests --no-install-recommends install \
        ffmpeg || apt-get -y install ffmpeg; \
    # 最后装服务相关包
    apt-get -y --no-install-suggests --no-install-recommends install \
        cron openssh-server; \
    dpkg --configure -a || true; \
    \
    # 清理 policy-rc.d 后再配置
    rm -f /usr/sbin/policy-rc.d /usr/sbin/dpkg-statoverride /usr/bin/chgrp /usr/bin/chown /usr/sbin/useradd; \
    \
    # 安装 TopSAP（使用 ar + tar --no-same-owner 绕过 chown 问题）
    echo Ubuntu >> /etc/issue; \
    if [ "$(uname -m)" = "x86_64" ]; then \
        debfile="/home/work/TopSAP-3.5.2.36.2-x86_64.deb"; \
    else \
        debfile="/home/work/TopSAP-3.5.2.36.2-aarch64.deb"; \
    fi; \
    mkdir -p /tmp/deb-extract /tmp/dpkg-info; \
    ar x "$debfile" --output /tmp/deb-extract; \
    for datafile in /tmp/deb-extract/data.tar.*; do \
        case "$datafile" in \
            *.gz) tar --no-same-owner --no-same-permissions -xzf "$datafile" -C /; break ;; \
            *.xz) tar --no-same-owner --no-same-permissions -xJf "$datafile" -C /; break ;; \
            *.zst) tar --no-same-owner --no-same-permissions --zstd -xf "$datafile" -C /; break ;; \
        esac; \
    done; \
    for ctlfile in /tmp/deb-extract/control.tar.*; do \
        case "$ctlfile" in \
            *.gz) tar --no-same-owner --no-same-permissions -xzf "$ctlfile" -C /tmp/dpkg-info; break ;; \
            *.xz) tar --no-same-owner --no-same-permissions -xJf "$ctlfile" -C /tmp/dpkg-info; break ;; \
            *.zst) tar --no-same-owner --no-same-permissions --zstd -xf "$ctlfile" -C /tmp/dpkg-info; break ;; \
        esac; \
    done; \
    /tmp/dpkg-info/postinst configure || true; \
    rm -f "$debfile"; \
    rm -rf /tmp/deb-extract /tmp/dpkg-info; \
    \
    # 从 TopSAP .bin 文件中提取 sv_websrv 及相关依赖
    /opt/TopSAP/TopSAP-*.bin --target /tmp/topsamp-extract --noexec 2>/dev/null || true; \
    cp -f /tmp/topsamp-extract/common/sv_websrv /opt/TopSAP/; \
    cp -f /tmp/topsamp-extract/common/libvpn_client.so /opt/TopSAP/; \
    cp -f /tmp/topsamp-extract/common/libes_3000gm.so.1.0.0 /opt/TopSAP/; \
    cp -f /tmp/topsamp-extract/common/libgm3000.1.0.so /opt/TopSAP/; \
    chmod +x /opt/TopSAP/sv_websrv; \
    # 设置库路径
    echo "/opt/TopSAP" > /etc/ld.so.conf.d/topsap.conf; \
    ldconfig; \
    rm -rf /tmp/topsamp-extract; \
    rm -rf /var/lib/apt/lists/*

# 安装 s6-overlay（按架构选择）
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64) s6arch="x86_64" ;; \
      aarch64|arm64) s6arch="aarch64" ;; \
      *) echo "Unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/s6-overlay-noarch.tar.xz \
      "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz"; \
    curl -fsSL -o /tmp/s6-overlay-arch.tar.xz \
      "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${s6arch}.tar.xz"; \
    tar -C / --no-same-owner --no-same-permissions --overwrite -xJf /tmp/s6-overlay-noarch.tar.xz; \
    tar -C / --no-same-owner --no-same-permissions --overwrite -xJf /tmp/s6-overlay-arch.tar.xz; \
    rm -f /tmp/s6-overlay-noarch.tar.xz /tmp/s6-overlay-arch.tar.xz

# s6 services: sshd / autologin / topsap_client （用 printf 写 run 文件，避免 heredoc）
RUN set -eux; \
    mkdir -p \
      /etc/s6-overlay/s6-rc.d/sshd \
      /etc/s6-overlay/s6-rc.d/autologin \
      /etc/s6-overlay/s6-rc.d/topsap_client \
      /etc/s6-overlay/s6-rc.d/user/contents.d; \
    \
    printf '%s\n' 'longrun' > /etc/s6-overlay/s6-rc.d/sshd/type; \
    printf '%s\n' 'longrun' > /etc/s6-overlay/s6-rc.d/autologin/type; \
    printf '%s\n' 'longrun' > /etc/s6-overlay/s6-rc.d/topsap_client/type; \
    \
    printf '%s\n' \
      '#!/bin/sh' \
      'set -e' \
      'mkdir -p /var/run/sshd' \
      'exec /usr/sbin/sshd -D -e' \
      > /etc/s6-overlay/s6-rc.d/sshd/run; \
    chmod 700 /etc/s6-overlay/s6-rc.d/sshd/run; \
    \
    printf '%s\n' \
      '#!/bin/sh' \
      'set -e' \
      'cd /home/work/Autologin' \
      'exec 2>&1' \
      'exec python3 app.py' \
      > /etc/s6-overlay/s6-rc.d/autologin/run; \
    chmod 700 /etc/s6-overlay/s6-rc.d/autologin/run; \
    \
    printf '%s\n' \
      '#!/bin/sh' \
      'set -e' \
      'cd /home/work/TopSap_Client' \
      'exec 2>&1' \
      'exec python3 top.py' \
      > /etc/s6-overlay/s6-rc.d/topsap_client/run; \
    chmod 700 /etc/s6-overlay/s6-rc.d/topsap_client/run; \
    \
    : > /etc/s6-overlay/s6-rc.d/user/contents.d/sshd; \
    : > /etc/s6-overlay/s6-rc.d/user/contents.d/autologin; \
    : > /etc/s6-overlay/s6-rc.d/user/contents.d/topsap_client

# SSH authorized_keys
RUN set -eux; \
    mkdir -p /root/.ssh; \
    chmod 700 /root/.ssh; \
    curl -fsSL https://github.com/zrubing.keys -o /root/.ssh/authorized_keys; \
    chmod 600 /root/.ssh/authorized_keys

# 拉取项目并安装 Python 依赖
ENV TOPSAP_CLIENT_VER="abc10d325d895c34c1f04f6464346bb238c0e0b8"

RUN set -eux; \
    python3 -m pip install --no-cache-dir --upgrade pip setuptools wheel; \
    wget -O /home/work/Autologin-main.tar.gz \
      https://github.com/zrubing/AutoLogin/archive/refs/heads/main.tar.gz; \
    wget -O /home/work/TopSap_Client-main.tar.gz \
      "https://github.com/zrubing/TopSAP_Client/archive/${TOPSAP_CLIENT_VER}.tar.gz"; \
    mkdir -p /home/work/TopSap_Client /home/work/Autologin; \
    tar -xzf /home/work/TopSap_Client-main.tar.gz -C /home/work/TopSap_Client --strip-components=1; \
    tar -xzf /home/work/Autologin-main.tar.gz -C /home/work/Autologin --strip-components=1; \
    rm -f /home/work/Autologin-main.tar.gz /home/work/TopSap_Client-main.tar.gz; \
    python3 -m pip install --no-cache-dir opencv-python; \
    (cd /home/work/TopSap_Client && python3 -m pip install --no-cache-dir -r requirements.txt); \
    (cd /home/work/Autologin && python3 -m pip install --no-cache-dir -r requirements.txt)

# 业务文件
COPY start.sh /home/work/start.sh
COPY danted.conf /etc/danted.conf
COPY expect.exp /home/work/expect.exp

RUN set -eux; \
    chmod +x /home/work/start.sh; \
    mkdir -p /etc/cont-init.d; \
    printf '%s\n' \
      '#!/bin/sh' \
      'set -e' \
      'exec /home/work/start.sh' \
      > /etc/cont-init.d/00-start; \
    chmod +x /etc/cont-init.d/00-start

ENTRYPOINT ["/init"]
