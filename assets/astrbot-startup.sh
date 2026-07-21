#!/bin/bash

ASTRBOT_APP_VERSION="{{VERSION}}"

# 自定义 Git Clone 命令（为空时使用默认逻辑）
CUSTOM_GIT_CLONE=""

# 重装插件依赖标记（1表示需要重装，执行后自动清除）
REINSTALL_PLUGINS_FLAG=0

# GitHub 代理选择：
# auto 表示按列表自动测试；direct 表示直连；其他值视为代理 URL。
ASTRBOT_GITHUB_PROXY="${ASTRBOT_GITHUB_PROXY:-auto}"
ASTRBOT_FORCE_REINSTALL_STEP="${ASTRBOT_FORCE_REINSTALL_STEP:-}"

export UV_LINK_MODE=copy
export UV_DEFAULT_INDEX="https://pypi.tuna.tsinghua.edu.cn/simple"
export UV_PYTHON_INSTALL_MIRROR="https://ghfast.top/https://github.com/astral-sh/python-build-standalone/releases/download"

if [ -z "$TMPDIR" ]; then
  echo "错误：未检测到 TMPDIR，请在挂载共享目录时传入 TMPDIR"
  exit 1
fi

if [ ! -d "$TMPDIR" ]; then
  echo "错误：临时目录 $TMPDIR 不存在，请确认挂载已经完成"
  exit 1
fi


progress_echo(){
  echo -e "\033[31m- $@\033[0m"
  echo "$@" > "$TMPDIR/progress_des"
}

prepare_reinstall_step(){
  case "$1" in
    uv)
      progress_echo "uv 重装准备中"
      rm -f "$HOME/.local/bin/uv" "$HOME/.local/bin/uvx"
      ;;
    napcat)
      progress_echo "NapCat 重装准备中"
      if [ -d "$HOME/napcat/config" ]; then
        rm -rf "$HOME/napcat_config_backup"
        cp -r "$HOME/napcat/config" "$HOME/napcat_config_backup"
      fi
      pkill -f 'qq --no-sandbox' 2>/dev/null || true
      pkill -f 'NapCat' 2>/dev/null || true
      pkill -f '/root/launcher_.*\.sh' 2>/dev/null || true
      pkill -f '/root/launcher\.sh' 2>/dev/null || true
      pkill -f 'napcat_instances/.*/launcher' 2>/dev/null || true
      rm -rf "$HOME/napcat" "$HOME/napcat.sh" "$HOME/launcher.sh" "$HOME/launcher.cpp" "$HOME/libnapcat_launcher.so"
      ;;
    astrbot)
      progress_echo "AstrBot 重装准备中"
      killall uv 2>/dev/null || true
      rm -rf "$HOME/AstrBot_data_reinstall_backup"
      if [ -d "$HOME/AstrBot/data" ]; then
        cp -r "$HOME/AstrBot/data" "$HOME/AstrBot_data_reinstall_backup"
      fi
      rm -rf "$HOME/AstrBot" "$HOME/AstrBot_tmp"
      ;;
  esac
}

maybe_prepare_reinstall(){
  if [ "$ASTRBOT_FORCE_REINSTALL_STEP" = "$1" ]; then
    prepare_reinstall_step "$1"
  fi
}

bump_progress(){
  current=0
  if [ -f "$TMPDIR/progress" ]; then
    current=$(cat "$TMPDIR/progress" 2>/dev/null || echo 0)
  fi
  next=$((current + 1))
  printf "$next" > "$TMPDIR/progress"
}

install_sudo_curl_git(){
  missing=()
  for cmd in sudo git curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if [ ${#missing[@]} -eq 0 ]; then
    progress_echo "基础命令已安装"
    return 0
  fi

  progress_echo "基础命令缺失: ${missing[*]}, 开始安装..."

  export DEBIAN_FRONTEND=noninteractive
  apt_opts="-o Acquire::ForceIPv4=true"

  if ! apt-get $apt_opts update; then
    echo "apt-get update 失败，继续尝试安装..."
  fi

  if ! apt-get $apt_opts install -y sudo git curl; then
    echo "基础命令安装失败"
    return 1
  fi

  for cmd in sudo git curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "基础命令安装后仍缺少: $cmd"
      return 1
    fi
  done

  progress_echo "基础命令安装完成"
}

network_test() {
    local timeout=10
    local status=0
    local found=0
    target_proxy=""
    echo "开始网络测试: Github..."

    if [ "$ASTRBOT_GITHUB_PROXY" = "direct" ]; then
        echo "已选择 Github 直连"
        target_proxy=""
        return 0
    fi

    if [ -n "$ASTRBOT_GITHUB_PROXY" ] && [ "$ASTRBOT_GITHUB_PROXY" != "auto" ]; then
        target_proxy="$ASTRBOT_GITHUB_PROXY"
        echo "已选择 Github 代理: $target_proxy"
        return 0
    fi

    proxy_arr=("https://ghfast.top" "https://gh-proxy.com" "https://ghproxy.net" "https://ghproxy.cc" "https://gh.dpik.top" "https://gh.monlor.com" "https://gh.chjina.com" "https://github.boki.moe" "https://gh.jasonzeng.dev" "https://gh.geekertao.top" "https://gh.nxnow.top" "https://down.npee.cn")
    check_url="https://raw.githubusercontent.com/astral-sh/uv/main/README.md"

    for proxy in "${proxy_arr[@]}"; do
        echo "测试代理: ${proxy}"
        status=$(curl -fL --connect-timeout ${timeout} --max-time $((timeout*2)) -o /dev/null -s -w "%{http_code}" "${proxy}/${check_url}")
        curl_exit=$?
        if [ $curl_exit -ne 0 ]; then
            echo "代理 ${proxy} 测试失败或超时，错误码: $curl_exit"
            continue
        fi
        if [ "${status}" = "200" ]; then
            found=1
            target_proxy="${proxy}"
            echo "将使用Github代理: ${proxy}"
            break
        fi
    done

    if [ ${found} -eq 0 ]; then
        echo "警告: 无法找到可用的Github代理，将尝试直连..."
        status=$(curl -fL --connect-timeout ${timeout} --max-time $((timeout*2)) -o /dev/null -s -w "%{http_code}" "${check_url}")
        if [ $? -eq 0 ] && [ "${status}" = "200" ]; then
            echo "直连Github成功，将不使用代理"
            target_proxy=""
        else
            echo "警告: 无法连接到Github，请检查网络。将继续尝试安装，但可能会失败。"
        fi
    fi
}

install_uv(){
  INSTALL_DIR="$HOME/.local/bin"
  if [ ! -x "$INSTALL_DIR/uv" ]; then
    progress_echo "uv $L_NOT_INSTALLED，$L_INSTALLING..."
    network_test
    APP_NAME="uv"
    APP_VERSION="0.9.9"
    ARCHIVE_FILE="uv-aarch64-unknown-linux-gnu.tar.gz"
    DOWNLOAD_URL="${target_proxy:+${target_proxy}/}https://github.com/astral-sh/uv/releases/download/${APP_VERSION}/${ARCHIVE_FILE}"

    # 检查必要命令
    for cmd in tar mkdir cp chmod mktemp rm curl; do
      if ! command -v $cmd >/dev/null 2>&1; then
        echo "错误：缺少必要命令 $cmd，无法安装 $APP_NAME"
        exit 1
      fi
    done

    # 创建安装目录和临时目录
    mkdir -p $INSTALL_DIR
    TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -t 'uvtmp.XXXXXX')
    if [ -z "$TMP_DIR" ]; then
      echo "创建临时目录失败"
      exit 1
    fi
    mkdir -p "$TMP_DIR"
    TMP_ARCHIVE="$TMP_DIR/$ARCHIVE_FILE"

    # 下载并解压（失败直接退出，不使用return）
    echo "正在下载 $APP_NAME $APP_VERSION..."
    if ! curl -fL $DOWNLOAD_URL -o $TMP_ARCHIVE; then
      echo "下载失败"
      rm -rf $TMP_DIR
      exit 1
    fi
    echo "正在解压 $APP_NAME..."
    if ! tar -C "$TMP_DIR" -xf "$TMP_ARCHIVE" --strip-components 1; then
      echo "解压失败"
      rm -rf $TMP_DIR
      exit 1
    fi

    # 安装并授权
    cp $TMP_DIR/uv $TMP_DIR/uvx $INSTALL_DIR/
    chmod +x $INSTALL_DIR/uv $INSTALL_DIR/uvx

    # 自动配置 PATH（写入 Ubuntu root 的 bashrc）
    if ! grep -q "$INSTALL_DIR" $HOME/.bashrc; then
      echo "export PATH=$INSTALL_DIR:\$PATH" >> $HOME/.bashrc
      source $HOME/.bashrc
      echo "已自动配置 $APP_NAME 路径到环境变量"
    fi

    # 清理临时文件
    rm -rf $TMP_DIR
  else
    progress_echo "uv $L_INSTALLED"
  fi
}

linuxqq_ready(){
  command -v qq >/dev/null 2>&1 &&
    dpkg-query -W -f='${Status}\n' linuxqq 2>/dev/null | grep -qx 'install ok installed'
}

prepare_apt_downloads(){
  local file changed=0
  export DEBIAN_FRONTEND=noninteractive
  mkdir -p /etc/apt/apt.conf.d
  printf 'Acquire::ForceIPv4 "true";\nAcquire::Retries "3";\n' > /etc/apt/apt.conf.d/99astrbot-force-ipv4
  for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$file" ] || continue
    if grep -q 'http://mirrors\.tuna\.tsinghua\.edu\.cn' "$file"; then
      sed -i 's#http://mirrors\.tuna\.tsinghua\.edu\.cn#https://mirrors.tuna.tsinghua.edu.cn#g' "$file"
      changed=1
    fi
  done
  if [ "$changed" -eq 1 ]; then
    echo "已将 Ubuntu 清华软件源切换为 HTTPS，正在刷新索引..."
    apt-get -o Acquire::ForceIPv4=true update
  fi
}

validate_linuxqq_deb(){
  local file="$1" arch package
  [ -s "$file" ] || return 1
  dpkg-deb --info "$file" >/dev/null 2>&1 || return 1
  dpkg-deb --contents "$file" >/dev/null 2>&1 || return 1
  arch=$(dpkg-deb -f "$file" Architecture 2>/dev/null)
  package=$(dpkg-deb -f "$file" Package 2>/dev/null)
  case "$arch" in arm64|aarch64) ;; *) return 1 ;; esac
  [ "$package" = "linuxqq" ]
}

use_local_linuxqq_deb(){
  local dest="$1" candidate
  for candidate in "${ASTRBOT_LINUXQQ_FILE:-}" /sdcard/Download/*.deb /storage/emulated/0/Download/*.deb; do
    [ -n "$candidate" ] && [ -f "$candidate" ] || continue
    validate_linuxqq_deb "$candidate" || continue
    echo "发现本地 LinuxQQ 安装包: $candidate"
    cp -f "$candidate" "$dest"
    return $?
  done
  return 1
}

get_linuxqq_signed_url(){
  local bare_url="$1"
  local api_url="https://im.qq.com/http2rpc/gotrpc/noauth/trpc.qqntv2.urlsign.UrlSign/GetSign"
  local response_file="$TMPDIR/linuxqq-sign.json"
  local normalized_file="$TMPDIR/linuxqq-sign-normalized.json"
  local payload
  LINUXQQ_SIGNED_URL=""
  payload=$(printf '{"url":"%s"}' "$bare_url")
  echo "正在向 LinuxQQ 官网申请临时下载签名..."
  if ! curl -fL --connect-timeout 15 --max-time 30 \
      -A 'Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 Chrome/124 Safari/537.36' \
      -e 'https://im.qq.com/' \
      -H 'Accept: application/json, text/plain, */*' \
      -H 'Content-Type: application/json' \
      -H 'x-oidb: {"uint32_command":"0x9b8e","uint32_service_type":1}' \
      --data "$payload" "$api_url" -o "$response_file"; then
    echo "获取 LinuxQQ 临时下载签名失败"
    return 1
  fi
  sed 's#\\/#/#g; s#\\u0026#\&#g; s#\\u003d#=#g' "$response_file" > "$normalized_file"
  LINUXQQ_SIGNED_URL=$(grep -Eo '"url"[[:space:]]*:[[:space:]]*"[^"]+"' "$normalized_file" |
    head -n 1 | sed -E 's/^"url"[[:space:]]*:[[:space:]]*"//; s/"$//')
case "$LINUXQQ_SIGNED_URL" in
https://*.deb|https://*.deb\?*) return 0 ;;
    *)
      echo "LinuxQQ 签名接口未返回有效下载地址"
      cat "$response_file" 2>/dev/null || true
      LINUXQQ_SIGNED_URL=""
      return 1
      ;;
  esac
}

install_linuxqq(){
  if linuxqq_ready; then
    echo "LinuxQQ 已安装"
    return 0
  fi

  local config_url="${ASTRBOT_LINUXQQ_CONFIG_URL:-https://cdn-go.cn/qq-web/im.qq.com_new/latest/rainbow/linuxConfig.js}"
  local config_file="$TMPDIR/linuxqq-config.js"
  local normalized_config="$TMPDIR/linuxqq-config-normalized.js"
  local qq_deb="$HOME/QQ.deb"
  local qq_deb_part="${qq_deb}.part"
  local qq_url="${ASTRBOT_LINUXQQ_URL:-}"
  local package_arch package_name sound_package download_url

echo "[AstrBot Android] LinuxQQ 修复流程 v9"
  progress_echo "LinuxQQ 安装中"
  rm -f "$config_file" "$normalized_config" "$qq_deb_part"

  if [ -z "$qq_url" ]; then
    echo "正在读取 LinuxQQ 官方发布配置..."
    if ! curl -fL --connect-timeout 15 --max-time 60 "$config_url" -o "$config_file"; then
      echo "获取 LinuxQQ 官方发布配置失败: $config_url"
      return 1
    fi
    sed 's#\\/#/#g' "$config_file" > "$normalized_config"
    qq_url=$(grep -Eo "(https?:)?//[^\"'[:space:]]+" "$normalized_config" |
      grep -Ei '(arm64|aarch64)[^[:space:]]*\.deb([?#][^[:space:]]*)?' |
      head -n 1)
    if [ -z "$qq_url" ]; then
      echo "官方发布配置中未找到 ARM64 LinuxQQ deb 下载地址"
      echo "可临时通过 ASTRBOT_LINUXQQ_URL 指定可信的 ARM64 deb 地址后重试"
      return 1
    fi
    case "$qq_url" in //*) qq_url="https:$qq_url" ;; esac
  fi

  if validate_linuxqq_deb "$qq_deb"; then
    echo "复用上次已下载并校验通过的 LinuxQQ 安装包"
  else
    if [ -f "$qq_deb" ]; then echo "发现不完整的 LinuxQQ 缓存，已清理并重新下载"; fi
    rm -f "$qq_deb" "$qq_deb_part"
echo "正在下载 LinuxQQ ARM64 安装包..."
download_url="$qq_url"
if ! curl -fL --connect-timeout 20 --max-time 600 \
        -A 'Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 Chrome/124 Safari/537.36' \
        -e 'https://im.qq.com/' "$download_url" -o "$qq_deb_part"; then
      rm -f "$qq_deb_part"
  echo "LinuxQQ 官网直链下载失败，尝试申请兼容签名..."
  if get_linuxqq_signed_url "$qq_url" && [ "$LINUXQQ_SIGNED_URL" != "$qq_url" ] &&
      curl -fL --connect-timeout 20 --max-time 600 \
        -A 'Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 Chrome/124 Safari/537.36' \
        -e 'https://im.qq.com/' "$LINUXQQ_SIGNED_URL" -o "$qq_deb_part"; then
    :
  else
    rm -f "$qq_deb_part"
    if ! use_local_linuxqq_deb "$qq_deb_part"; then
      echo "LinuxQQ 官网下载安装包失败"
      return 1
    fi
  fi
fi
    if ! validate_linuxqq_deb "$qq_deb_part"; then
      echo "LinuxQQ 下载文件不完整或校验失败"
      rm -f "$qq_deb_part"
      return 1
    fi
    if ! mv -f "$qq_deb_part" "$qq_deb"; then
      echo "保存 LinuxQQ 安装包失败"
      rm -f "$qq_deb_part"
      return 1
    fi
  fi
  if ! validate_linuxqq_deb "$qq_deb"; then
    echo "LinuxQQ 安装包完整性校验失败"
    rm -f "$qq_deb"
    return 1
  fi

  package_arch=$(dpkg-deb -f "$qq_deb" Architecture 2>/dev/null)
  package_name=$(dpkg-deb -f "$qq_deb" Package 2>/dev/null)
  case "$package_arch" in arm64|aarch64) ;; *)
    echo "LinuxQQ 安装包架构不匹配: ${package_arch:-未知} (需要 arm64)"
    rm -f "$qq_deb"
    return 1
  esac
  if [ "$package_name" != "linuxqq" ]; then
    echo "LinuxQQ 安装包名称异常: ${package_name:-未知}"
    rm -f "$qq_deb"
    return 1
  fi

  if apt-cache show libasound2t64 >/dev/null 2>&1; then
    sound_package=libasound2t64
  else
    sound_package=libasound2
  fi
  if ! apt-get install -y libnss3 libgbm1 "$sound_package"; then
    echo "LinuxQQ 运行依赖安装失败"
    return 1
  fi
  if ! apt-get install -y "$qq_deb"; then
    echo "LinuxQQ deb 安装失败"
    return 1
  fi
  if ! linuxqq_ready; then
    echo "LinuxQQ 安装后的命令/包状态验收失败"
    return 1
  fi

  rm -f "$config_file" "$normalized_config" "$qq_deb"
  progress_echo "LinuxQQ 安装完成"
}

patch_napcat_installer(){
  local installer="$1"
  # 上游历史脚本会让 curl 在 HTTP 404 时继续，并固定使用 Ubuntu 24.04 已淘汰的 libasound2。
  sed -i -E 's/curl[[:space:]]+-k[[:space:]]+-L/curl -fL/g; s/curl[[:space:]]+-kL/curl -fL/g' "$installer"
  if apt-cache show libasound2t64 >/dev/null 2>&1; then
    sed -i -E 's/(^|[^[:alnum:]_])libasound2([^[:alnum:]_]|$)/\1libasound2t64\2/g' "$installer"
  fi
  # 本脚本已用官网签名地址安装并验收 LinuxQQ；上游主流程仍会无条件调用旧版 install_linuxqq。
  # 只替换主流程中的独立调用行，保留函数定义，避免再次下载已失效的固定版本。
  sed -i -E 's/^[[:space:]]*install_linuxqq[[:space:]]*$/log "LinuxQQ 已由 AstrBot Android 安装，跳过上游重复安装"/' "$installer"
  if grep -qE '^[[:space:]]*install_linuxqq[[:space:]]*$' "$installer"; then
    echo "修补 NapCat 上游 LinuxQQ 重复安装步骤失败"
    return 1
  fi
}

install_napcat(){
  # 检查是否完整安装。旧版本可能留下 launcher.sh，但 LinuxQQ 或依赖包安装失败。
  if ! check_napcat_ready >/dev/null 2>&1; then
    progress_echo "Napcat $L_NOT_INSTALLED，$L_INSTALLING..."

    if ! prepare_apt_downloads; then
      echo "Ubuntu 软件源刷新失败，请检查上方 apt 输出"
      exit 1
    fi
    
    if ! apt --fix-broken install -y; then
      echo "apt 修复依赖失败，继续执行安装并在结束时做完整校验"
    fi

    # 先修复最容易失效的 LinuxQQ 下载。失败时保留现有 NapCat 文件与配置，便于直接重试。
    if ! install_linuxqq; then
      echo "LinuxQQ 安装失败，NapCat 安装已中止"
      exit 1
    fi

    # 备份配置目录（如果存在）
    if [ -d "$HOME/napcat/config" ]; then
      echo "备份 NapCat 配置目录..."
      cp -r "$HOME/napcat/config" "$HOME/napcat_config_backup"
    fi
    
    rm -rf "$HOME/napcat" "$HOME/napcat.sh" "$HOME/launcher.sh" "$HOME/launcher.cpp" "$HOME/libnapcat_launcher.so"
    cd $HOME
    echo "Napcat $L_NOT_INSTALLED，$L_INSTALLING..."
    if ! curl -fL -o napcat.sh https://raw.githubusercontent.com/NapNeko/napcat-linux-installer/refs/heads/main/install.sh; then
      echo "下载 napcat.sh 失败"
      exit 1
    fi
    if ! chmod +x napcat.sh; then
      echo "设置 napcat.sh 执行权限失败"
      exit 1
    fi
    if ! patch_napcat_installer napcat.sh; then echo "修补 napcat.sh 失败"; exit 1; fi
    if ! bash napcat.sh; then
      echo "NapCat 上游安装脚本执行失败"
      exit 1
    fi

    # 环境管理的 NapCat 步骤只做安装，不做登录启动。
    # 有些上游安装脚本会在安装结束后顺手启动 QQ/NapCat，这里统一收掉，
    # 后续从主页账号卡片手动启动。
    pkill -f 'qq --no-sandbox' 2>/dev/null || true
    pkill -f 'NapCat' 2>/dev/null || true
    pkill -f '/root/launcher_.*\.sh' 2>/dev/null || true
    pkill -f '/root/launcher\.sh' 2>/dev/null || true
    pkill -f 'napcat_instances/.*/launcher' 2>/dev/null || true
    
    # 恢复配置目录
    if [ -d "$HOME/napcat_config_backup" ]; then
      echo "恢复 NapCat 配置目录..."
      mkdir -p "$HOME/napcat/config"
      cp -r "$HOME/napcat_config_backup"/* "$HOME/napcat/config/"
      rm -rf "$HOME/napcat_config_backup"
    fi
    
  # 只在配置文件不存在时写入默认配置
  if [ ! -f "$HOME/napcat/config/onebot11.json" ]; then
    echo "写入 onebot11.json 默认配置文件"
    cat > "$HOME/napcat/config/onebot11.json" <<EOF
{
  "network": {
    "httpServers": [],
    "httpClients": [],
    "websocketServers": [],
    "websocketClients": [
      {
        "name": "WsClient",
        "enable": true,
        "url": "ws://localhost:${ASTRBOT_ONEBOT_WS_PORT:-6199}/ws",
        "messagePostFormat": "array",
        "reportSelfMessage": false,
        "reconnectInterval": 5000,
        "token": "kasdkfljsadhlskdjhasdlkfshdlafksjdhf",
        "debug": false,
        "heartInterval": 30000
      }
    ]
  },
  "musicSignUrl": "",
  "enableLocalFile2Url": false,
  "parseMultMsg": false
}
EOF
  fi
fi
  configure_napcat_token_ttl
  if ! check_napcat_ready; then
    echo "NapCat 安装不完整，请查看上方 apt/dpkg/curl 错误后重试"
    exit 1
  fi
  progress_echo "Napcat $L_INSTALLED"
}

configure_napcat_token_ttl(){
  if [ -f "$HOME/napcat/napcat.mjs" ]; then
    sed -i -E "s#static MAX_CREDENTIAL_VALID_SECONDS = [0-9]+#static MAX_CREDENTIAL_VALID_SECONDS = 604800#g" "$HOME/napcat/napcat.mjs"
    sed -i -E 's#Rp\.set\(`revoked:\$\{r\}`, !0, [0-9]+\)#Rp.set(`revoked:${r}`, !0, 604800)#g' "$HOME/napcat/napcat.mjs"
  fi
}

check_napcat_ready(){
  local missing=0

  if ! command -v qq >/dev/null 2>&1; then
    echo "[AstrBot Android] missing NapCat dependency: qq"
    missing=1
  fi

  if ! command -v Xvfb >/dev/null 2>&1; then
    echo "[AstrBot Android] missing NapCat dependency: Xvfb"
    missing=1
  fi

  if ! dpkg -s linuxqq 2>/dev/null | grep -q "Status: install ok installed"; then
    echo "[AstrBot Android] missing or broken NapCat dependency: linuxqq"
    missing=1
  fi

  if ! dpkg -s libnss3 2>/dev/null | grep -q "Status: install ok installed"; then
    echo "[AstrBot Android] missing or broken NapCat dependency: libnss3"
    missing=1
  fi

  if ! dpkg -s libnspr4 2>/dev/null | grep -q "Status: install ok installed"; then
    echo "[AstrBot Android] missing or broken NapCat dependency: libnspr4"
    missing=1
  fi

  if ! { dpkg -s libasound2t64 2>/dev/null || dpkg -s libasound2 2>/dev/null; } | grep -q "Status: install ok installed"; then
    echo "[AstrBot Android] missing or broken NapCat dependency: libasound2/libasound2t64"
    missing=1
  fi

  if [ ! -f "$HOME/launcher.sh" ]; then
    echo "[AstrBot Android] missing NapCat launcher: $HOME/launcher.sh"
    missing=1
  fi

  if [ ! -f "$HOME/libnapcat_launcher.so" ]; then
    echo "[AstrBot Android] missing NapCat launcher library: $HOME/libnapcat_launcher.so"
    missing=1
  fi

  if [ ! -d "$HOME/napcat" ]; then
    echo "[AstrBot Android] missing NapCat directory: $HOME/napcat"
    missing=1
  fi

  if [ "$missing" -ne 0 ]; then
    return 1
  fi

  return 0
}

check_astrbot_ready(){
  local missing=0

  if ! command -v curl >/dev/null 2>&1; then
    echo "[AstrBot Android] missing dependency: curl"
    missing=1
  fi

  if ! command -v git >/dev/null 2>&1; then
    echo "[AstrBot Android] missing dependency: git"
    missing=1
  fi

  if [ ! -x "$HOME/.local/bin/uv" ]; then
    echo "[AstrBot Android] missing dependency: uv"
    missing=1
  fi

  if [ ! -d "$HOME/AstrBot" ]; then
    echo "[AstrBot Android] missing runtime: AstrBot"
    missing=1
  fi

  if [ ! -d "$HOME/AstrBot/.venv" ]; then
    echo "[AstrBot Android] missing runtime: AstrBot .venv"
    missing=1
  elif ! cd "$HOME/AstrBot" || ! "$HOME/.local/bin/uv" run --no-sync python -c "import aiohttp" >/dev/null 2>&1; then
    echo "[AstrBot Android] missing dependency: aiohttp"
    missing=1
  fi

  if [ "$missing" -ne 0 ]; then
    echo "__ASTRBOT_MANUAL_ENV_REQUIRED__"
    echo "Environment is not ready. Open Home -> Environment Manager and install the missing steps."
    return 1
  fi

  return 0
}

install_astrbot(){
  local INSTALL_DIR="$HOME/AstrBot"
  local CLONE_TEMP_DIR="$HOME/AstrBot_tmp"
  local BACKUP_DIR="/sdcard/Download/AstrBotBubble"

  rm -rf "$CLONE_TEMP_DIR"

  killall uv 2>/dev/null

  if [ -d "$INSTALL_DIR" ] && { [ ! -f "$INSTALL_DIR/pyproject.toml" ] || [ ! -f "$INSTALL_DIR/main.py" ]; }; then
    echo "AstrBot 安装目录不完整，准备重新安装..."
    rm -rf "$HOME/AstrBot_data_reinstall_backup"
    if [ -d "$INSTALL_DIR/data" ]; then
      cp -r "$INSTALL_DIR/data" "$HOME/AstrBot_data_reinstall_backup"
    fi
    rm -rf "$INSTALL_DIR"
  fi

  # 检查是否已安装
  if [ ! -d "$INSTALL_DIR" ]; then
    cd $HOME
    progress_echo "AstrBot $L_NOT_INSTALLED，$L_INSTALLING..."

    # 克隆仓库（失败直接退出）
    echo "正在获取 AstrBot 最新版本..."

    # 判断是否使用自定义 git clone 命令
    if [ -n "$CUSTOM_GIT_CLONE" ]; then
      echo "使用自定义 Git Clone 命令..."
      echo "执行: $CUSTOM_GIT_CLONE"
      # 执行自定义命令，假设克隆到当前目录，然后重命名为临时目录
      if ! eval "$CUSTOM_GIT_CLONE"; then
        echo "自定义 Git Clone 命令执行失败"
        exit 1
      fi
      # 查找克隆后的目录（通常是 AstrBot）
      if [ -d "AstrBot" ]; then
        mv "AstrBot" "$CLONE_TEMP_DIR"
      else
        echo "错误: 自定义 git clone 后未找到 AstrBot 目录"
        exit 1
      fi
    else
      network_test
      
      # 使用默认逻辑：获取最新的正式版 tag，跳过 beta/alpha/rc/dev/pre 等预发布版本
      LATEST_TAG=$(git ls-remote --tags --sort='-v:refname' ${target_proxy:+${target_proxy}/}https://github.com/AstrBotDevs/AstrBot.git | awk -F'/' '{print $3}' | sed 's/\^{}//g' | grep -E '^v?[0-9]+(\.[0-9]+){1,2}$' | head -n 1)

      if [ -z "$LATEST_TAG" ]; then
        echo "警告: 无法获取最新 tag，使用 master 分支"
        CLONE_BRANCH="master"
      else
        echo "最新正式版: $LATEST_TAG"
        CLONE_BRANCH="$LATEST_TAG"
      fi

      # 克隆到临时目录
      echo "正在克隆 AstrBot 仓库，分支/标签: $CLONE_BRANCH..."
      if ! git clone --depth=1 --branch "$CLONE_BRANCH" ${target_proxy:+${target_proxy}/}https://github.com/AstrBotDevs/AstrBot.git "$CLONE_TEMP_DIR"; then
        echo "克隆 AstrBot 仓库失败"
        rm -rf "$CLONE_TEMP_DIR"  # 清理失败的临时目录
        exit 1
      fi
    fi

    # 原子性重命名
    mv "$CLONE_TEMP_DIR" "$INSTALL_DIR"

  else
    progress_echo "AstrBot $L_INSTALLED"
  fi

  progress_echo "AstrBot 初始化中"
  cd "$INSTALL_DIR"

  if [ ! -d "$INSTALL_DIR/data" ]; then

    echo "检测到 data 目录不存在，初始化数据目录..."
    mkdir "$INSTALL_DIR/data"

    if [ -d "$HOME/AstrBot_data_reinstall_backup" ]; then
      echo "恢复重装前 AstrBot 数据..."
      rm -rf "$INSTALL_DIR/data"
      mv "$HOME/AstrBot_data_reinstall_backup" "$INSTALL_DIR/data"
      REINSTALL_PLUGINS_FLAG=1
    else
    
    # 检查并恢复最新备份
    if [ -d "$BACKUP_DIR" ]; then
      echo "扫描备份目录: $BACKUP_DIR"
      LATEST_BACKUP=$(ls -t "$BACKUP_DIR"/AstrBotBubble-backup-*.tar.gz 2>/dev/null | head -n 1)
      
      if [ -n "$LATEST_BACKUP" ]; then
        echo "找到备份文件: $LATEST_BACKUP"
        echo "恢复 AstrBot 数据备份..."
        
        # 解压备份到 data 目录
        if tar -xzf "$LATEST_BACKUP" -C "$INSTALL_DIR"; then
          echo "备份恢复成功"
          echo "AstrBot 数据已从备份恢复"
          REINSTALL_PLUGINS_FLAG=1  # 备份恢复成功，需要重装插件依赖

        else
          echo "备份恢复失败，使用默认配置"
          cp "$HOME/cmd_config.json" "$INSTALL_DIR/data"
          chmod +w "$INSTALL_DIR/data/cmd_config.json"
        fi
      else
        echo "未找到备份文件，使用默认配置"
        cp "$HOME/cmd_config.json" "$INSTALL_DIR/data"
        chmod +w "$INSTALL_DIR/data/cmd_config.json"
        echo "拷贝 cmd_config.json 默认配置文件"
      fi
    else
      echo "备份目录不存在，使用默认配置"
      cp "$HOME/cmd_config.json" "$INSTALL_DIR/data"
      chmod +w "$INSTALL_DIR/data/cmd_config.json"
      echo "拷贝 cmd_config.json 默认配置文件"
    fi
    fi
    
    rm -rf "$INSTALL_DIR/.venv"

  fi

  if [ ! -d "$INSTALL_DIR/.venv" ] || ! $HOME/.local/bin/uv run --no-sync python -c "import aiohttp" >/dev/null 2>&1; then

    # 使用 uv sync 同步依赖
    echo "同步 AstrBot 依赖..."
    if ! $HOME/.local/bin/uv sync; then
      echo "依赖同步失败"
      exit 1
    fi

    REINSTALL_PLUGINS_FLAG=1  # .venv 不存在，需要重装插件依赖
  fi

  # 检查是否需要重装插件依赖（根据标记）
  if [ "$REINSTALL_PLUGINS_FLAG" -eq 1 ]; then

    echo "检测到重装插件依赖标记，开始重装..."
    # 清除标记（将脚本中的标记重置为0）
    sed -i 's/^REINSTALL_PLUGINS_FLAG=1$/REINSTALL_PLUGINS_FLAG=0/' /root/astrbot-startup.sh

    # 扫描所有插件的 requirements.txt 并安装到 venv
    echo "扫描插件依赖..."
    if [ -d "$INSTALL_DIR/data/plugins" ]; then
      for plugin_dir in "$INSTALL_DIR/data/plugins"/*; do
        if [ -d "$plugin_dir" ] && [ -f "$plugin_dir/requirements.txt" ]; then
          echo "发现插件依赖: $plugin_dir/requirements.txt"
          if [ -f "$HOME/.local/bin/uv" ]; then
            cd "$INSTALL_DIR"
            echo "安装插件依赖: $(basename "$plugin_dir")..."
            $HOME/.local/bin/uv pip install -r "$plugin_dir/requirements.txt" 2>/dev/null || echo "警告: 插件依赖安装失败，将在启动时重试"
          fi
        fi
      done
    fi
  fi

  progress_echo "AstrBot 安装完成"
}

launch_astrbot(){
  local INSTALL_DIR="$HOME/AstrBot"

  if ! check_astrbot_ready; then
    return 1
  fi

  cd "$INSTALL_DIR"
  if [ ! -f "$HOME/.local/bin/uv" ]; then
    echo "uv 未找到"
    exit 1
  fi

  # 使用 uv run --no-sync main.py 启动（跳过依赖同步）
  progress_echo "AstrBot 启动中"

  if ! $HOME/.local/bin/uv run --no-sync main.py; then
    echo "AstrBot 启动失败"
    exit 1
  fi

}

run_step(){
  case "$1" in
    start)
      launch_astrbot
      ;;
    base)
      maybe_prepare_reinstall base
      install_sudo_curl_git
      ;;
    uv)
      maybe_prepare_reinstall uv
      install_sudo_curl_git
      install_uv
      ;;
    napcat)
      maybe_prepare_reinstall napcat
      install_sudo_curl_git
      install_napcat
      ;;
    astrbot)
      maybe_prepare_reinstall astrbot
      install_sudo_curl_git
      install_uv
      install_astrbot
      ;;
    all|"")
      install_sudo_curl_git
      bump_progress
      bump_progress
      install_uv
      bump_progress
      install_napcat
      bump_progress
      bump_progress
      bump_progress
      install_astrbot
      ;;
    *)
      echo "未知步骤: $1"
      echo "可用步骤: base uv napcat astrbot ports all"
      exit 1
      ;;
  esac
}

if [ "$1" = "--step" ]; then
  run_step "$2"
else
  run_step start
fi
