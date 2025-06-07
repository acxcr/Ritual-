#!/usr/bin/env bash

# 检查是否以 root 用户运行脚本
if [ "$(id -u)" != "0" ]; then
    echo "此脚本需要以 root 用户权限运行。"
    echo "请尝试使用 'sudo -i' 命令切换到 root 用户，然后再次运行此脚本。"
    exit 1
fi

# 脚本保存路径 (来自你的原始脚本)
SCRIPT_PATH="$HOME/Ritual.sh"

# --- 辅助函数：检查并停用虚拟环境 ---
function deactivate_if_active() {
    if type deactivate > /dev/null 2>&1; then # 更简洁的检查方法
        echo "[提示] 停用 Python 虚拟环境"
        deactivate
    fi
}

# 修改 docker-compose.yaml 文件端口映射 (来自你的原始脚本)
function modify_docker_compose_ports() {
    local compose_file="deploy/docker-compose.yaml" # 脚本执行时，当前工作目录应为 infernet-container-starter
    echo "修改 $compose_file 文件端口映射..."

    if [ ! -f "$compose_file" ]; then
        echo "[错误] $compose_file 文件不存在！请确保当前在 infernet-container-starter 目录内。"
        return 1
    fi

    sed -i 's/- "0.0.0.0:4000:4000"/- "0.0.0.0:4050:4000"/' "$compose_file"
    sed -i 's/- "8545:3000"/- "8550:3000"/' "$compose_file"

    if grep -q "0.0.0.0:4050:4000" "$compose_file" && grep -q "8550:3000" "$compose_file"; then
        echo "[提示] 端口映射修改成功！"
    else
        echo "[警告] 端口映射修改可能失败，请检查 $compose_file 文件内容。"
    fi
}

# 安装 Ritual 节点函数 (整合核心修改，尽可能保留原始脚本逻辑)
function install_ritual_node() {
    # 假设脚本启动时，用户已在 /root 目录 (这是你的执行习惯)

    # 系统更新及必要的软件包安装
    echo "系统更新及安装必要的包..."
    sudo apt update && sudo apt upgrade -y
    # --- 核心修改：确保 python3-venv 已安装 ---
    sudo apt -qy install curl git jq lz4 build-essential screen python3 python3-pip python3-venv

    # Docker 和 Docker Compose 安装检查 (基本沿用原始脚本逻辑)
    echo "检查 Docker 是否已安装..."
    if command -v docker &> /dev/null; then
      echo " - Docker 已安装，跳过此步骤。"
    else
      echo " - Docker 未安装，正在进行安装..."
      sudo apt install -y docker.io || { echo "[错误] Docker 安装失败"; return 1; }
      sudo systemctl enable docker
      sudo systemctl start docker
    fi

    echo "检查 Docker Compose 是否已安装..."
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
      echo " - Docker Compose 未安装，正在进行安装..."
      # 沿用你原始脚本中的 Docker Compose 安装方式（特定版本）
      sudo curl -L "https://github.com/docker/compose/releases/download/v2.29.2/docker-compose-$(uname -s)-$(uname -m)" \
           -o /usr/local/bin/docker-compose || { echo "[错误] Docker Compose 下载失败"; return 1; }
      sudo chmod +x /usr/local/bin/docker-compose
      # 你原始脚本中还有创建 cli-plugins 目录的逻辑，如果需要请保留或调整
      # DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
      # mkdir -p $DOCKER_CONFIG/cli-plugins
      # curl -SL https://github.com/docker/compose/releases/download/v2.20.2/docker-compose-linux-x86_64 -o $DOCKER_CONFIG/cli-plugins/docker-compose
      # chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose
    else
      echo " - Docker Compose 已安装，跳过此步骤。"
    fi
    echo "[确认] Docker Compose 版本:"
    docker compose version || docker-compose --version # 兼容旧版

    # Foundry 安装 (沿用原始脚本逻辑，HOME 在 root 用户下为 /root)
    echo
    echo "安装 Foundry "
    if pgrep anvil &>/dev/null; then
      echo "[警告] anvil 正在运行，正在关闭以更新 Foundry。"
      pkill anvil; sleep 2
    fi
    
    # 记录脚本启动时的目录（即/root），以便Foundry安装后能返回
    script_launch_dir=$(pwd) 

    cd "$HOME" || { echo "[错误] 无法切换到 $HOME 目录进行Foundry安装"; return 1; }
    mkdir -p foundry
    cd foundry || { echo "[错误] 无法切换到 $HOME/foundry 目录"; cd "$script_launch_dir"; return 1; }
    curl -L https://foundry.paradigm.xyz | bash || { echo "[错误] Foundry 安装脚本下载或执行失败"; cd "$script_launch_dir"; return 1; }
    
    FOUNDRY_BIN_DIR="$HOME/.foundry/bin"
    "$FOUNDRY_BIN_DIR/foundryup" || { echo "[错误] foundryup 执行失败"; cd "$script_launch_dir"; return 1; }

    if [[ ":$PATH:" != *":$FOUNDRY_BIN_DIR:"* ]]; then
      export PATH="$FOUNDRY_BIN_DIR:$PATH" 
      if ! grep -q "export PATH=\"$FOUNDRY_BIN_DIR:\$PATH\"" "$HOME/.bashrc"; then
         echo 'export PATH="$HOME/.foundry/bin:$PATH"' >> "$HOME/.bashrc"
      fi
    fi
    cd "$script_launch_dir" # 返回到脚本启动时的目录 (即 /root)

    echo "[确认] forge 版本:"
    # 调用 $HOME/.foundry/bin/forge 以确保不受 PATH 延迟影响
    if ! "$FOUNDRY_BIN_DIR/forge" --version; then 
      echo "[错误] 无法找到 forge 命令，Foundry 安装失败。"
      return 1
    fi
    if [ -f /usr/bin/forge ]; then # 原始脚本逻辑
      echo "[提示] 删除 /usr/bin/forge 以避免 ZOE 冲突..." 
      sudo rm -f /usr/bin/forge
    fi
    echo "[提示] Foundry 安装及环境变量配置完成。"
    # 原始脚本中 cd ~ || exit 1 在此之后，现已通过 script_launch_dir 管理，此处不需要再 cd ~

    # 克隆 infernet-container-starter (当前工作目录是你启动脚本时的 /root)
    echo
    echo "克隆 infernet-container-starter..."
    if [ -d "infernet-container-starter" ]; then # 检查 /root/infernet-container-starter
        echo "[提示] infernet-container-starter 目录已存在，将尝试进入并更新..."
        cd infernet-container-starter || { echo "[错误] 进入已存在的 infernet-container-starter 目录失败"; return 1; }
        git pull
    else
        git clone https://github.com/ritual-net/infernet-container-starter
        cd infernet-container-starter || { echo "[错误] 进入新克隆的 infernet-container-starter 目录失败"; return 1; }
    fi
    
    # VENV_DIR 定义在克隆并进入 infernet-container-starter 之后
    VENV_DIR="$(pwd)/ritual_venv" # 在 /root/infernet-container-starter 内部创建 ritual_venv

    echo "[提示]将在以下路径创建Python虚拟环境: $VENV_DIR"
    if [ -d "$VENV_DIR" ]; then
        echo "[提示] 虚拟环境目录 $VENV_DIR 已存在。"
    else
        python3 -m venv "$VENV_DIR" || { echo "[错误] 创建虚拟环境 $VENV_DIR 失败"; return 1; }
    fi

    echo "[提示] 在虚拟环境中升级 pip 并安装 infernet-cli / infernet-client"
    "$VENV_DIR/bin/python3" -m pip install --upgrade pip
    "$VENV_DIR/bin/python3" -m pip install infernet-cli infernet-client

    echo "[提示] 激活 Python 虚拟环境 $VENV_DIR"
    # shellcheck source=/dev/null
    source "$VENV_DIR/bin/activate"

    docker pull ritualnetwork/hello-world-infernet:latest # 原始脚本逻辑

    echo "检查 screen 会话 ritual 是否存在..." # 原始脚本逻辑
    if screen -list | grep -q "ritual"; then
        echo "[提示] 发现 ritual 会话正在运行，正在终止..."
        screen -S ritual -X quit; sleep 1
    fi
    echo "在 screen -S ritual 会话中开始容器部署..."
    sleep 1
    # --- 核心修改：确保 screen 内部使用虚拟环境 ---
    screen -S ritual -dm bash -c "source '$VENV_DIR/bin/activate'; project=hello-world make deploy-container; exec bash"
    echo "[提示] 部署工作正在后台的 screen 会话 (ritual) 中进行。"

    echo
    echo "配置 Ritual Node 文件..."
    read -p "请输入您的 Private Key (0x...): " PRIVATE_KEY # 原始脚本 read -p

    # modify_docker_compose_ports 在当前目录 (应为 /root/infernet-container-starter) 下操作 deploy/docker-compose.yaml
    modify_docker_compose_ports

    # 原始脚本的参数变量声明 (严格保持)
    RPC_URL="https://mainnet.base.org/" 
    RPC_URL_SUB="https://mainnet.base.org/" 
    REGISTRY="0x3B1554f346DFe5c482Bb4BA31b880c1C18412170"
    SLEEP=3
    START_SUB_ID=160000 
    BATCH_SIZE=50  
    TRAIL_HEAD_BLOCKS=3
    INFERNET_VERSION="1.4.0" 

    echo "[提示] 正在修改配置文件 (严格遵循原始脚本的sed路径和值逻辑)..."
    
    # --- 第一批 sed (使用相对路径，因为当前工作目录是 /root/infernet-container-starter) ---
    sed -i "s|\"registry_address\": \".*\"|\"registry_address\": \"$REGISTRY\"|" deploy/config.json
    sed -i "s|\"private_key\": \".*\"|\"private_key\": \"$PRIVATE_KEY\"|" deploy/config.json
    sed -i "s|\"sleep\": [0-9]*|\"sleep\": $SLEEP|" deploy/config.json # 原始脚本这里没处理小数
    sed -i "s|\"starting_sub_id\": [0-9]*|\"starting_sub_id\": $START_SUB_ID|" deploy/config.json # 使用脚本变量初始值
    sed -i "s|\"batch_size\": [0-9]*|\"batch_size\": $BATCH_SIZE|" deploy/config.json
    sed -i "s|\"trail_head_blocks\": [0-9]*|\"trail_head_blocks\": $TRAIL_HEAD_BLOCKS|" deploy/config.json
    sed -i "s|\"rpc_url\": \".*\"|\"rpc_url\": \"$RPC_URL\"|" deploy/config.json # config.json 的 rpc_url 先设为 $RPC_URL

    sed -i "s|\"registry_address\": \".*\"|\"registry_address\": \"$REGISTRY\"|" projects/hello-world/container/config.json
    sed -i "s|\"private_key\": \".*\"|\"private_key\": \"$PRIVATE_KEY\"|" projects/hello-world/container/config.json
    sed -i "s|\"sleep\": [0-9]*|\"sleep\": $SLEEP|" projects/hello-world/container/config.json
    sed -i "s|\"starting_sub_id\": [0-9]*|\"starting_sub_id\": $START_SUB_ID|" projects/hello-world/container/config.json
    sed -i "s|\"batch_size\": [0-9]*|\"batch_size\": $BATCH_SIZE|" projects/hello-world/container/config.json
    sed -i "s|\"trail_head_blocks\": [0-9]*|\"trail_head_blocks\": $TRAIL_HEAD_BLOCKS|" projects/hello-world/container/config.json
    sed -i "s|\"rpc_url\": \".*\"|\"rpc_url\": \"$RPC_URL\"|" projects/hello-world/container/config.json

    sed -i "s|\(registry\s*=\s*\).*|\1$REGISTRY;|" projects/hello-world/contracts/script/Deploy.s.sol
    # 合约部署/调用 RPC 指向你脚本定义的 $RPC_URL (https://mainnet.base.org/)，基于你之前的反馈和教程
    sed -i "s|\(RPC_URL\s*=\s*\).*|\1\"$RPC_URL\";|" projects/hello-world/contracts/script/Deploy.s.sol

    # 原始脚本将 infernet-node 镜像改为 latest
    sed -i 's|ritualnetwork/infernet-node:[^"]*|ritualnetwork/infernet-node:latest|' deploy/docker-compose.yaml

    MAKEFILE_PATH="projects/hello-world/contracts/Makefile" 
    sed -i "s|^sender := .*|sender := $PRIVATE_KEY|" "$MAKEFILE_PATH"
    sed -i "s|^RPC_URL := .*|RPC_URL := $RPC_URL|" "$MAKEFILE_PATH"

    # --- 第二批 sed (使用绝对路径 /root/infernet-container-starter/，严格按照你原始脚本的写法) ---
    # 这些会覆盖上面 config.json 中的一些设置
    sed -i 's|"rpc_url": ".*"|"rpc_url": "https://base.drpc.org"|' /root/infernet-container-starter/deploy/config.json
    sed -i 's|"rpc_url": ".*"|"rpc_url": "https://base.drpc.org"|' /root/infernet-container-starter/projects/hello-world/container/config.json
    sed -i "s|\"batch_size\": [0-9]*|\"batch_size\": $BATCH_SIZE|" /root/infernet-container-starter/deploy/config.json
    sed -i "s|\"sleep\": [0-9]\+\(\.[0-9]\+\)\?|\"sleep\": $SLEEP|" /root/infernet-container-starter/deploy/config.json 
    sed -i "s|\"sleep\": [0-9]\+\(\.[0-9]\+\)\?|\"sleep\": $SLEEP|" /root/infernet-container-starter/projects/hello-world/container/config.json

    sed -i "s|\"sync_period\": [0-9]\+\(\.[0-9]\+\)\?|\"sync_period\": 30|" /root/infernet-container-starter/deploy/config.json
    sed -i "s|\"sync_period\": [0-9]\+\(\.[0-9]\+\)\?|\"sync_period\": 30|" /root/infernet-container-starter/projects/hello-world/container/config.json
    # 原始脚本将 starting_sub_id 覆盖为 244000
    sed -i "s|\"starting_sub_id\": [0-9]\+\(\.[0-9]\+\)\?|\"starting_sub_id\": 244000|" /root/infernet-container-starter/deploy/config.json
    sed -i "s|\"starting_sub_id\": [0-9]\+\(\.[0-9]\+\)\?|\"starting_sub_id\": 244000|" /root/infernet-container-starter/projects/hello-world/container/config.json

    sed -i "s|\"batch_size\": [0-9]*|\"batch_size\": $BATCH_SIZE|" /root/infernet-container-starter/projects/hello-world/container/config.json
    
    # 原始脚本中后续针对 Deploy.s.sol 和 Makefile 的绝对路径 sed 命令，也会使用 $RPC_URL (https://mainnet.base.org/)
    sed -i "s|\(RPC_URL\s*=\s*\).*|\1\"$RPC_URL\";|" /root/infernet-container-starter/projects/hello-world/contracts/script/Deploy.s.sol
    # 原始脚本中 MAKEFILE_PATH 变量被用于相对路径和绝对路径的 sed。这里沿用其对绝对路径的用法。
    # 注意，如果你的原始脚本中这个变量名是 MAKEFILE_PATH_ABS，请改回。
    # 我这里统一使用 MAKEFILE_PATH_FOR_ABS 来避免与上面相对路径的 MAKEFILE_PATH 混淆，并指向正确文件。
    MAKEFILE_PATH_FOR_ABS="/root/infernet-container-starter/projects/hello-world/contracts/Makefile" 
    sed -i "s|^RPC_URL := .*|RPC_URL := $RPC_URL|" "$MAKEFILE_PATH_FOR_ABS"
    
    # 原始脚本的 Docker Compose 重启
    echo
    echo "docker compose down & up..."
    docker compose -f deploy/docker-compose.yaml down
    docker compose -f deploy/docker-compose.yaml up -d

    echo
    echo "[提示] 容器正在后台 (-d) 运行。"
    echo "使用 docker ps 查看状态。日志查看：docker logs infernet-node"

    # 原始脚本的 Forge 库安装 (当前工作目录是 /root/infernet-container-starter)
    echo
    echo "安装 Forge (项目依赖)"
    cd projects/hello-world/contracts || { echo "[错误] 切换到合约目录失败"; deactivate_if_active; return 1; }
    rm -rf lib/forge-std 
    rm -rf lib/infernet-sdk
    forge install --no-git foundry-rs/forge-std
    forge install --no-git ritual-net/infernet-sdk
    cd ../../.. # 返回到 infernet-container-starter 根目录

    # 原始脚本的再次 Docker Compose 重启
    echo
    echo "重启 docker compose..."
    docker compose -f deploy/docker-compose.yaml down
    docker compose -f deploy/docker-compose.yaml up -d
    echo "[提示] 查看 infernet-node 日志：docker logs infernet-node"

    # 原始脚本的部署项目合约
    echo
    echo "部署项目合约 (目标RPC: $RPC_URL)..."
    DEPLOY_OUTPUT=$(project=hello-world make deploy-contracts 2>&1)
    echo "$DEPLOY_OUTPUT"

    NEW_ADDR=$(echo "$DEPLOY_OUTPUT" | grep -oP 'Deployed SaysHello:\s+\K0x[0-9a-fA-F]{40}')
    if [ -z "$NEW_ADDR" ]; then
      echo "[警告] 未找到新合约地址。可能需要手动更新 CallContract.s.sol."
    else
      echo "[提示] 部署的 SaysHello 地址: $NEW_ADDR"
      sed -i "s|SaysGM saysGm = SaysGM(0x[0-9a-fA-F]\+);|SaysGM saysGm = SaysGM($NEW_ADDR);|" \
          projects/hello-world/contracts/script/CallContract.s.sol

      echo
      echo "使用新地址执行 call-contract (目标RPC: $RPC_URL)..."
      project=hello-world make call-contract
      if [ $? -ne 0 ]; then 
          echo "[警告] make call-contract 执行失败。请检查目标网络 ($RPC_URL) 上的合约状态、账户资金和Gas设置。"
      else
          echo "[提示] make call-contract 执行成功。"
      fi

      # 原始脚本的下载 diyujiedian.sh
      echo "拉取diyujiedian"
      wget -O /root/diyujiedian.sh https://raw.githubusercontent.com/sdohuajia/Ritual/refs/heads/main/diyujiedian.sh
      wget -O /root/anvil.sh https://raw.githubusercontent.com/sdohuajia/Ritual/refs/heads/main/anvil.sh
      
      chmod +x /root/diyujiedian.sh
      chmod +x /root/anvil.sh

      # --- 调整：先清理旧的diyujiedian screen会话，再启动新的 ---
      if screen -list | grep -q "diyujiedian"; then
          echo "[提示] 发现旧的 diyujiedian 会话正在运行，正在终止..."
          screen -S diyujiedian -X quit; sleep 1
      fi
      echo "[提示] 正在启动新的 diyujiedian screen 会话..."
      # --- 核心修改：确保 screen 内部使用虚拟环境 (如果 diyujiedian.sh 需要) ---
      screen -S diyujiedian -dm bash -c "source '$VENV_DIR/bin/activate'; /root/diyujiedian.sh; exec bash"
    fi

    echo
    echo "===== Ritual Node 完成====="

    deactivate_if_active 
      
    # 沿用你原始脚本的 read 方式
    read -n 1 -s -r -p "按任意键返回主菜单..."
    main_menu
}

# 主菜单函数 (来自你的原始脚本)
function main_menu() {
    while true; do
        clear
        echo "脚本由大赌社区哈哈哈哈编写，推特 @ferdie_jhovie，免费开源，请勿相信收费"
        echo "如有问题，可联系推特，仅此只有一个号"
        echo "感谢严不由衷的代码贡献"
        echo "================================================================"
        echo "退出脚本，请按键盘 ctrl + C 退出即可"
        echo "请选择要执行的操作:"
        echo "1) 安装 Ritual 节点"
        echo "2. 查看 Ritual 节点日志"
        echo "3. 删除 Ritual 节点"
        echo "4. 退出脚本"
        
        read -p "请输入您的选择: " choice

        case $choice in
            1) 
                install_ritual_node
                ;;
            2)
                view_logs
                ;;
            3)
                remove_ritual_node
                ;;
            4)
                echo "退出脚本！"
                exit 0
                ;;
            *)
                echo "无效选项，请重新选择。"
                ;;
        esac

        echo "按任意键继续..."
        read -n 1 -s
    done
}

# 查看 Ritual 节点日志 (来自你的原始脚本)
function view_logs() {
    echo "正在查看 Ritual 节点日志..."
    # 根据 docker-compose.yaml，主要的节点容器名叫 infernet-node
    docker logs -f infernet-node 
}

# 删除 Ritual 节点 (来自你的原始脚本，但增强了镜像删除)
function remove_ritual_node() {
    echo "正在删除 Ritual 节点..."

    # 原始脚本的删除逻辑，假定在 /root/infernet-container-starter
    PROJECT_TO_REMOVE_PATH="/root/infernet-container-starter"

    echo "停止并移除 Docker 容器..."
    if [ -d "$PROJECT_TO_REMOVE_PATH" ]; then
        if cd "$PROJECT_TO_REMOVE_PATH"; then
            if [ -f "deploy/docker-compose.yaml" ]; then
                docker compose -f deploy/docker-compose.yaml down --remove-orphans -v 
            else
                echo "[警告] 未在 $PROJECT_TO_REMOVE_PATH/deploy/ 找到 docker-compose.yaml 文件。"
                echo "尝试按已知名称停止和删除容器..."
                docker stop infernet-node infernet-redis infernet-fluentbit infernet-anvil > /dev/null 2>&1
                docker rm infernet-node infernet-redis infernet-fluentbit infernet-anvil > /dev/null 2>&1
            fi
            cd /root # 操作完成后返回 /root
        else
            echo "[警告] 无法进入 $PROJECT_TO_REMOVE_PATH 目录。"
             # 后备逻辑
            echo "尝试按已知名称停止和删除容器..."
            docker stop infernet-node infernet-redis infernet-fluentbit infernet-anvil > /dev/null 2>&1
            docker rm infernet-node infernet-redis infernet-fluentbit infernet-anvil > /dev/null 2>&1
        fi
    else
        echo "[警告] 未找到 $PROJECT_TO_REMOVE_PATH 目录。"
        # 后备逻辑
        echo "尝试按已知名称停止和删除容器..."
        docker stop infernet-node infernet-redis infernet-fluentbit infernet-anvil > /dev/null 2>&1
        docker rm infernet-node infernet-redis infernet-fluentbit infernet-anvil > /dev/null 2>&1
    fi
    
    echo "删除相关文件和目录..."
    # 原始脚本是 rm -rf ~/infernet-container-starter
    # 既然我们确定在 /root 下，就直接用这个路径
    rm -rf "$PROJECT_TO_REMOVE_PATH" 

    echo "删除 Docker 镜像..."
    # --- 增强：尝试强制删除，并列出所有相关镜像 ---
    docker rmi -f ritualnetwork/hello-world-infernet:latest
    docker rmi -f ritualnetwork/infernet-node:latest # 因为脚本中 sed 改为 latest
    # 以下是可选的，清理其他相关镜像
    # docker rmi -f ritualnetwork/infernet-anvil:1.0.0
    # docker rmi -f redis:7.4.0
    # docker rmi -f fluent/fluent-bit:3.1.4

    echo "Ritual 节点已成功删除！"
}

# 调用主菜单函数
main_menu
