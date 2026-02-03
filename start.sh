#!/command/with-contenv bash

# 判断tun0是否存在的
if [ -e /dev/net/tun ]; then
  :
else
  echo "/dev/net/tun doesn't exist. Please create it first." >&2
  exit 1
fi

# 定义一个处理函数，用于在接收到 INT 信号时退出脚本
function cleanup {
  echo "Exiting script..."
  exit 0
}
# 捕获 INT 信号，并调用 cleanup 函数
trap cleanup INT

# sed -i "s/{{server_address}}/$SERVER_ADDRESS/g" expect.exp
# sed -i "s/{{user_name}}/$USER_NAME/g" expect.exp
# sed -i "s/{{password}}/$PASSWORD/g" expect.exp

# 启动 sv_websrv 并等待其就绪
cd /opt/TopSAP && ./sv_websrv >/home/work/sv_websrv.log 2>&1 &
SV_WEBSRV_PID=$!

# 等待 sv_websrv 启动（最多等待 60 秒）
echo "Waiting for sv_websrv to start on port 7443..."
for i in {1..60}; do
    # 优先检查端口监听，因为 HTTPS 检查可能在证书未就绪时失败
    if ss -ln | grep -q ':7443'; then
        echo "sv_websrv is listening on port 7443 (took ${i}s)"
        break
    fi
    if ! kill -0 $SV_WEBSRV_PID 2>/dev/null; then
        echo "ERROR: sv_websrv process died!" >&2
        cat /home/work/sv_websrv.log >&2
        exit 1
    fi
    sleep 1
done

# 最终检查 - 只检查端口，不检查 HTTPS（避免证书问题）
if ! ss -ln | grep -q ':7443'; then
    echo "ERROR: sv_websrv failed to start within 60 seconds" >&2
    echo "sv_websrv log:" >&2
    cat /home/work/sv_websrv.log >&2
    exit 1
fi


# expect -f expect.exp

for i in {1..10}; do
  if [ -e "/sys/class/net/tun0" ]; then
    # 如果设备存在，跳出循环
    danted -f /etc/danted.conf &
    break
  else
    # 如果设备不存在，等待三秒后进行下一次判断
    sleep 3
  fi
done

# 循环结束后判断设备是否存在
if [ ! -e "/sys/class/net/tun0" ]; then
  echo "Device tun0 not found."
  exit 1
fi

# 更改MTU（与 topsap 的默认值保持一致）
ip link set dev tun0 mtu 1300

# 添加NAT转发，使其他请求可以走正常出口，不全部走代理，例如公网请求
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
wait
