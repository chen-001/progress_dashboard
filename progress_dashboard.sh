#!/bin/bash

# Progress Dashboard 服务管理脚本
# 用于管理 run_pools_queue 进度监控 Dashboard

# 项目配置
PROJECT_DIR="/home/chenzongwei/progress_dashboard"
PYTHON_PATH="/home/chenzongwei/.conda/envs/chenzongwei311/bin/python"
START_SCRIPT="server.py"
SCRIPT_PATH="$(realpath "$0")"
SERVICE_NAME="progress-dashboard.service"
LOG_FILE="$PROJECT_DIR/logs/dashboard.log"
PID_FILE="$PROJECT_DIR/dashboard.pid"
DAEMON_PID_FILE="$PROJECT_DIR/daemon.pid"

# 默认配置
DEFAULT_HOST="0.0.0.0"
DEFAULT_PORT="8080"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() {
    echo -e "${BLUE}===========================================================${NC}"
    echo -e "${BLUE}           Progress Dashboard 服务管理工具${NC}"
    echo -e "${BLUE}===========================================================${NC}"
    echo -e "${CYAN}项目目录: ${PROJECT_DIR}${NC}"
    echo -e "${CYAN}Python: ${PYTHON_PATH}${NC}"
}

is_pid_active() {
    local pid="$1"
    [ -z "$pid" ] && return 1
    kill -0 "$pid" 2>/dev/null || return 1
    local stat=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    [ -z "$stat" ] || [[ "$stat" == Z* ]] && return 1
    return 0
}

launch_detached() {
    local stdout_target="$1"
    shift
    if command -v setsid >/dev/null 2>&1; then
        setsid "$@" >> "$stdout_target" 2>&1 < /dev/null &
    else
        nohup "$@" >> "$stdout_target" 2>&1 < /dev/null &
    fi
    echo $!
}

get_pid() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if is_pid_active "$pid"; then
            echo "$pid"
            return 0
        else
            rm -f "$PID_FILE"
        fi
    fi
    local pid=$(pgrep -f "$PYTHON_PATH $PROJECT_DIR/$START_SCRIPT" | head -1)
    if [ -n "$pid" ]; then
        echo "$pid" > "$PID_FILE"
        echo "$pid"
        return 0
    fi
    return 1
}

check_process() {
    local pid=$(get_pid)
    if [ -n "$pid" ]; then
        echo -e "${GREEN}Progress Dashboard 正在运行 (PID: $pid)${NC}"
        local port="${PD_PORT:-$DEFAULT_PORT}"
        if ss -ltn 2>/dev/null | grep -q ":$port "; then
            echo -e "${CYAN}监听端口: $port${NC}"
            echo -e "${CYAN}访问地址: http://localhost:$port${NC}"
        fi
        return 0
    else
        echo -e "${RED}Progress Dashboard 未运行${NC}"
        return 1
    fi
}

start_app() {
    mkdir -p "$(dirname "$LOG_FILE")"
    local host="${PD_HOST:-$DEFAULT_HOST}"
    local port="${PD_PORT:-$DEFAULT_PORT}"

    local existing_pid=$(get_pid)
    if [ -n "$existing_pid" ]; then
        echo "$existing_pid" > "$PID_FILE"
        return 0
    fi

    cd "$PROJECT_DIR" || return 1
    local pid=$(launch_detached "$LOG_FILE" "$PYTHON_PATH" "$PROJECT_DIR/$START_SCRIPT" --host "$host" --port "$port")
    echo "$pid" > "$PID_FILE"
    return 0
}

wait_for_app_start() {
    local port="${PD_PORT:-$DEFAULT_PORT}"
    local retries="${1:-15}"
    local count=0
    while [ $count -lt "$retries" ]; do
        local pid=$(get_pid)
        if [ -n "$pid" ] && ss -ltn 2>/dev/null | grep -q ":$port "; then
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    return 1
}

daemon_process() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$$" > "$DAEMON_PID_FILE"
    trap 'rm -f "$DAEMON_PID_FILE"; exit 0' INT TERM EXIT
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 守护进程启动" >> "$LOG_FILE"

    while true; do
        if ! check_process > /dev/null 2>&1; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - 检测到服务已停止，正在重启..." >> "$LOG_FILE"
            start_app
            if wait_for_app_start 15; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - 服务重启成功" >> "$LOG_FILE"
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') - 服务重启失败，等待下次尝试" >> "$LOG_FILE"
            fi
        fi
        sleep 5
    done
}

start_service() {
    print_header
    echo -e "${BLUE}启动 Progress Dashboard 保活服务...${NC}"

    if [ ! -f "$PYTHON_PATH" ]; then
        echo -e "${RED}✗ Python路径不存在: $PYTHON_PATH${NC}"
        return 1
    fi
    if [ ! -f "$PROJECT_DIR/$START_SCRIPT" ]; then
        echo -e "${RED}✗ 启动脚本不存在: $PROJECT_DIR/$START_SCRIPT${NC}"
        return 1
    fi

    # 检查守护进程是否已运行
    if [ -f "$DAEMON_PID_FILE" ]; then
        local daemon_pid=$(cat "$DAEMON_PID_FILE" 2>/dev/null)
        if is_pid_active "$daemon_pid"; then
            echo -e "${YELLOW}保活服务已在运行 (守护进程PID: $daemon_pid)${NC}"
            check_process
            return 0
        else
            rm -f "$DAEMON_PID_FILE"
        fi
    fi

    local host="${PD_HOST:-$DEFAULT_HOST}"
    local port="${PD_PORT:-$DEFAULT_PORT}"
    echo -e "${CYAN}配置: HOST=$host, PORT=$port${NC}"

    local daemon_pid=$(launch_detached /dev/null "$SCRIPT_PATH" daemon-loop)
    echo "$daemon_pid" > "$DAEMON_PID_FILE"

    if wait_for_app_start 20 && kill -0 "$daemon_pid" 2>/dev/null; then
        echo -e "${GREEN}✓ Progress Dashboard 保活服务启动成功${NC}"
        echo -e "守护进程PID: ${CYAN}$daemon_pid${NC}"
        echo -e "访问地址: ${BLUE}http://$host:$port${NC}"
        echo -e "日志文件: ${CYAN}$LOG_FILE${NC}"
        return 0
    else
        echo -e "${RED}✗ 启动失败，查看日志: $LOG_FILE${NC}"
        kill "$daemon_pid" 2>/dev/null
        rm -f "$DAEMON_PID_FILE"
        return 1
    fi
}

stop_service() {
    print_header
    echo -e "${BLUE}停止 Progress Dashboard 保活服务...${NC}"

    # 停止守护进程
    if [ -f "$DAEMON_PID_FILE" ]; then
        local daemon_pid=$(cat "$DAEMON_PID_FILE" 2>/dev/null)
        if is_pid_active "$daemon_pid"; then
            kill "$daemon_pid" 2>/dev/null
            local count=0
            while [ $count -lt 5 ]; do
                is_pid_active "$daemon_pid" || break
                sleep 1; count=$((count + 1))
            done
            is_pid_active "$daemon_pid" && kill -9 "$daemon_pid" 2>/dev/null
            echo -e "${GREEN}✓ 守护进程已停止${NC}"
        fi
        rm -f "$DAEMON_PID_FILE"
    fi

    # 停止应用
    local pid=$(get_pid)
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null
        local count=0
        while [ $count -lt 10 ]; do
            is_pid_active "$pid" || break
            sleep 1; count=$((count + 1))
        done
        is_pid_active "$pid" && kill -9 "$pid" 2>/dev/null
        rm -f "$PID_FILE"
        echo -e "${GREEN}✓ Progress Dashboard 已停止${NC}"
    else
        echo -e "${YELLOW}应用未运行${NC}"
    fi
}

restart_service() {
    stop_service
    sleep 2
    start_service
}

print_status() {
    print_header
    echo -e "\n${YELLOW}=== 服务状态 ===${NC}"
    check_process

    if [ -f "$DAEMON_PID_FILE" ]; then
        local daemon_pid=$(cat "$DAEMON_PID_FILE" 2>/dev/null)
        if is_pid_active "$daemon_pid"; then
            echo -e "${GREEN}守护进程正在运行 (PID: $daemon_pid)${NC}"
        else
            echo -e "${RED}守护进程未运行${NC}"
            rm -f "$DAEMON_PID_FILE"
        fi
    else
        echo -e "${YELLOW}守护进程未启用${NC}"
    fi

    local port="${PD_PORT:-$DEFAULT_PORT}"
    echo -e "\n${BLUE}=== 端口状态 ===${NC}"
    ss -ltn 2>/dev/null | grep -q ":$port " && echo -e "端口 $port: ${GREEN}已监听${NC}" || echo -e "端口 $port: ${RED}未监听${NC}"

    [ -f "$LOG_FILE" ] && echo -e "日志文件: ${CYAN}$(du -h "$LOG_FILE" | awk '{print $1}')${NC}"
}

show_logs() {
    echo -e "${BLUE}实时日志 (Ctrl+C 退出):${NC}"
    [ -f "$LOG_FILE" ] && tail -f "$LOG_FILE" || echo -e "${YELLOW}日志文件不存在${NC}"
}

show_help() {
    print_header
    echo -e "\n使用方法: $0 [命令]"
    echo -e "\n${GREEN}命令:${NC}"
    echo -e "  ${GREEN}start${NC}     启动保活服务（自动重启）"
    echo -e "  ${YELLOW}stop${NC}      停止保活服务"
    echo -e "  ${BLUE}restart${NC}   重启保活服务"
    echo -e "  ${BLUE}status${NC}    查看服务状态"
    echo -e "  ${CYAN}logs${NC}      查看实时日志"
    echo -e "  ${CYAN}cleanup${NC}   清理临时文件"
    echo -e "\n${GREEN}环境变量:${NC}"
    echo -e "  ${CYAN}PD_HOST${NC}   服务器地址 (默认: $DEFAULT_HOST)"
    echo -e "  ${CYAN}PD_PORT${NC}   服务器端口 (默认: $DEFAULT_PORT)"
    echo -e "\n${GREEN}示例:${NC}"
    echo -e "  $0 start                # 启动保活服务"
    echo -e "  PD_PORT=9090 $0 start  # 指定端口启动"
    echo -e "  $0 status               # 查看状态"
    echo -e "  $0 logs                 # 查看日志"
}

# 主程序
case "$1" in
    start)   start_service ;;
    stop)    stop_service ;;
    restart) restart_service ;;
    status)  print_status ;;
    logs)    show_logs ;;
    cleanup)
        rm -f "$PID_FILE" "$DAEMON_PID_FILE"
        echo -e "${GREEN}✓ 已清理临时文件${NC}"
        ;;
    daemon-loop) daemon_process ;;
    help|--help|-h) show_help ;;
    *) show_help; exit 1 ;;
esac
