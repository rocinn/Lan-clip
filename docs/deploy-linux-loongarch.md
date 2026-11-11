# Linux / LoongArch 本机部署说明

本文记录 `feature/3a6000nuc-abi1` 分支在 **本机（LoongArch / Loongnix）** 上的适配结果，
方便换机或重装后按同样步骤恢复。

## 本机环境

| 项目 | 值 |
| --- | --- |
| 主机名 | `<HOSTNAME>`（以本机实际主机名为准） |
| 发行版 | Loongnix GNU/Linux 25 |
| 内核 | `6.6.52-loong64` |
| 架构 | `loongarch64`（新世界，`ld-linux-loongarch-lp64d.so.1`，glibc 2.41） |
| Python | 3.13.5（`/usr/bin/python3`，系统自带的 pip/ensurepip 均未安装） |
| 服务端口 | 5000（`0.0.0.0`，仅 IPv4） |
| 显示环境 | X11（`DISPLAY=:0`） |

本机是 LoongArch 新世界 ABI，且系统 Python 没有 pip。因此依赖不能直接
`pip install --user`，改为放在项目内 `.venv`。

## 目录与文件

```
Lan-clip/
├── .venv/          # 本机虚拟环境（已被 .gitignore 忽略，不提交）
├── setup.sh        # 创建 .venv 并安装服务端依赖
├── start.sh        # 启动 / 停止 / 重启 / 状态 / 开机自启
├── stop.sh         # 停止服务
├── run/            # 自管守护进程 PID（忽略）
└── logs/           # 运行日志（忽略）
```

## 首次安装

```bash
cd /path/to/Lan-clip
./setup.sh
```

`setup.sh` 的行为：

1. 优先用 `python3 -m venv .venv` 创建虚拟环境；
2. 本机没有 `ensurepip` 时自动退回 `python3 -m virtualenv .venv`；
3. 从清华 PyPI 镜像安装 `flask`、`waitress`、`qrcode` 三个服务端依赖；
4. 已安装且可导入时直接退出，可重复执行。

> 本机 `Pillow` 没有 LoongArch 的 PyPI 轮子，从源码编译又缺 zlib 开发头文件，
> 因此 `setup.sh` 不安装托盘相关依赖（`pillow` / `pystray` / `pyperclip`）。
> 本机也没有 `xclip`，托盘剪贴板监听暂不可用；普通 Web 服务不受影响。

## 日常使用

```bash
./start.sh                 # 后台启动（默认 5000）
./start.sh 5080            # 指定端口
./start.sh status          # 查看状态、监听地址、局域网 URL
./start.sh restart         # 重启
./stop.sh                  # 停止
```

已 `enable` systemd 时，端口以服务单元里的 `--port` 为准：

- `./start.sh 5080`：自动把单元端口改成 5080，重载并重启服务；
- `./start.sh` / `./stop.sh` 不带端口：沿用单元里配置的端口，不会出现「状态显示 5000、实际跑在 5080」的错位；
- 首次安装并想用非默认端口：`./start.sh 5080 enable`，命令和端口顺序任意。

`start.sh` 会自动选择解释器：

1. `LANCLIP_PYTHON` 环境变量（必须是可执行文件路径）；
2. 项目内 `.venv/bin/python`；
3. 系统 `python3`。

因此本机直接执行即可，无需先 `source .venv/bin/activate`。

## 开机自启（systemd 用户级）

```bash
./start.sh enable     # 安装 ~/.config/systemd/user/lanclip.service，并开启 linger
./start.sh disable    # 取消开机自启
```

本机已执行过 `enable`，当前状态：

```text
systemctl --user is-active lanclip   -> active
systemctl --user is-enabled lanclip  -> enabled
loginctl show-user "$USER" -p Linger -> Linger=yes
```

因此无需登录图形桌面，开机后由 systemd 直接拉起。日志：

```bash
journalctl --user -u lanclip -f
tail -f logs/lanclip.log
```

如果换机后 `loginctl enable-linger` 因权限失败，手动执行一次：

```bash
sudo loginctl enable-linger "$USER"
```

## 本机适配点

### 1. 解释器与依赖

- `start.sh` / `stop.sh` 不再硬编码 `python3`，优先使用 `.venv`；
- systemd 单元的 `ExecStart` 使用绝对路径并加引号（systemd 不搜索 `PATH`，
  路径中的中文也能正确处理）；
- `setup.sh` 处理 Loongnix 没有 `ensurepip` 的情况。

### 2. 局域网地址识别（`net_utils.py`）

本机 `/etc/hosts` 把主机名 `<HOSTNAME>` 映射到 `127.0.1.1`，原来的
`socket.getaddrinfo(hostname)` 只能拿到回环地址，终端二维码只显示 `127.0.0.1`。

现在 Linux 上优先调用 `hostname -I` 获取真实网卡地址，再按原有规则过滤虚拟网段。
本机实测输出（地址已脱敏）：

```text
<LAN-IP-1>  (enp5s0, IPv4, 默认路由)
<LAN-IP-2>  (wlp6s0, IPv4)
```

### 3. 只展示 IPv4 地址

`app.py` 里 Waitress 使用 `host="0.0.0.0"`，只监听 IPv4；之前终端会同时列出
IPv6 地址，但用这些地址访问会连接失败。现在 `net_utils.display_server_info()`
和 `start.sh` 只展示 IPv4 地址。

如果以后需要 IPv6，除了让 Waitress 绑定 `::`，还要在 firewalld 放行对应端口。

### 4. firewalld 放行端口

本机 `firewalld` 默认 `public` zone 只放行 `ssh` 和 `dhcpv6-client`，
5000 端口从其他设备访问会被直接拒绝，表现为「本机能打开、手机/其他电脑打不开」。

已执行并持久化：

```bash
firewall-cmd --add-port=5000/tcp
firewall-cmd --permanent --add-port=5000/tcp
```

确认：

```bash
firewall-cmd --list-ports
# 5000/tcp
firewall-cmd --permanent --list-ports
# 5000/tcp
```

如果换了端口（例如 `./start.sh 5080`），需要同步放行新端口：

```bash
firewall-cmd --permanent --add-port=5080/tcp
firewall-cmd --reload
```

`./start.sh status` 会区分两种情况：

- 当前运行时没放行：提示会被局域网拦截；
- 当前已放行但没写永久配置：提示重启后会失效。

## 验证记录（2026-11-11）

```text
./setup.sh                     -> 依赖已就绪
bash -n start.sh stop.sh       -> 通过
python -m py_compile app.py    -> 通过
./start.sh                     -> 启动成功，API 200
./start.sh status              -> systemd active，0.0.0.0:5000 监听
curl 127.0.0.1:5000/api/cards/status -> 200 JSON
curl http://<LAN-IP>:5000/     -> 200
./stop.sh                      -> inactive，端口释放
./start.sh                     -> systemd 重新拉起，API 200
./start.sh 5080                -> 重写 unit 并切到 5080，API 200
./start.sh 5000                -> 切回 5000
firewall-cmd --list-ports      -> 5000/tcp
firewall-cmd --permanent --list-ports -> 5000/tcp
```
