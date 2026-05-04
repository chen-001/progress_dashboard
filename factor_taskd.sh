#!/bin/bash
# factor_taskd.sh — 因子计算任务守护进程管理脚本
# 同 progress_dashboard.sh 模式，管理 factor_taskd 的启停

PROJECT_DIR="/home/chenzongwei/rust_pyfunc"
PYTHON_PATH="/home/chenzongwei/.conda/envs/chenzongwei311/bin/python"
DAEMON_SCRIPT="$PROJECT_DIR/python/rust_pyfunc/factor_taskd.py"
SCRIPT_PATH="$(realpath "$0")"
SERVICE_NAME="factor-taskd.service"
LOG_FILE="/home/chenzongwei/.factor_taskd/daemon.log"
PID_FILE="/home/chenzongwei/.factor_taskd/daemon.pid"

DEFAULT_HOST="127.0.0.1"
DEFAULT_PORT="9099"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() {
    echo -e "${BLUE}===========================================================${NC}"
    echo -e "${BLUE}           factor_taskd — 因子计算任务守护进程${NC}"
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
    local pid=$(pgrep -f "$PYTHON_PATH.*factor_taskd.py" | head -1)
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
        echo -e "${GREEN}factor_taskd 正在运行 (PID: $pid)${NC}"
        local port="${FTD_PORT:-$DEFAULT_PORT}"
        if ss -ltn 2>/dev/null | grep -q ":$port "; then
            echo -e "${CYAN}监听端口: $port${NC}"
            echo -e "${CYAN}API 地址: http://localhost:$port/api/tasks${NC}"
        fi
        return 0
    else
        echo -e "${RED}factor_taskd 未运行${NC}"
        return 1
    fi
}

start_app() {
    mkdir -p "$(dirname "$LOG_FILE")"
    local host="${FTD_HOST:-$DEFAULT_HOST}"
    local port="${FTD_PORT:-$DEFAULT_PORT}"

    local existing_pid=$(get_pid)
    if [ -n "$existing_pid" ]; then
        echo "$existing_pid" > "$PID_FILE"
        return 0
    fi

    cd "$PROJECT_DIR" || return 1
    local pid=$(launch_detached "$LOG_FILE" "$PYTHON_PATH" "$DAEMON_SCRIPT" --host "$host" --port "$port")
    echo "$pid" > "$PID_FILE"
    return 0
}

wait_for_app_start() {
    local port="${FTD_PORT:-$DEFAULT_PORT}"
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

start_service() {
    print_header
    echo -e "${BLUE}启动 factor_taskd...${NC}"

    if [ ! -f "$PYTHON_PATH" ]; then
        echo -e "${RED}✗ Python路径不存在: $PYTHON_PATH${NC}"
        return 1
    fi
    if [ ! -f "$DAEMON_SCRIPT" ]; then
        echo -e "${RED}✗ 启动脚本不存在: $DAEMON_SCRIPT${NC}"
        return 1
    fi

    start_app
    if wait_for_app_start 20; then
        local pid=$(get_pid)
        echo -e "${GREEN}✓ factor_taskd 启动成功${NC}"
        echo -e "PID: ${CYAN}$pid${NC}"
        echo -e "API: ${BLUE}http://${FTD_HOST:-$DEFAULT_HOST}:${FTD_PORT:-$DEFAULT_PORT}${NC}"
        echo -e "日志: ${CYAN}$LOG_FILE${NC}"
        echo -e "\n${YELLOW}CLI 使用:${NC}"
        echo -e "  python $PROJECT_DIR/python/rust_pyfunc/factor_task.py list"
        echo -e "  python $PROJECT_DIR/python/rust_pyfunc/factor_task.py submit <script.py>"
        return 0
    else
        echo -e "${RED}✗ 启动失败，查看日志: $LOG_FILE${NC}"
        return 1
    fi
}

stop_service() {
    print_header
    echo -e "${BLUE}停止 factor_taskd...${NC}"

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
        echo -e "${GREEN}✓ factor_taskd 已停止${NC}"
    else
        echo -e "${YELLOW}factor_taskd 未运行${NC}"
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
    [ -f "$LOG_FILE" ] && echo -e "日志大小: ${CYAN}$(du -h "$LOG_FILE" | awk '{print $1}')${NC}"
}

show_logs() {
    echo -e "${BLUE}实时日志 (Ctrl+C 退出):${NC}"
    [ -f "$LOG_FILE" ] && tail -f "$LOG_FILE" || echo -e "${YELLOW}日志文件不存在${NC}"
}

show_help() {
    print_header
    echo -e "\n使用方法: $0 [命令]"
    echo -e "\n${GREEN}命令:${NC}"
    echo -e "  ${GREEN}start${NC}     启动 factor_taskd 守护进程"
    echo -e "  ${YELLOW}stop${NC}      停止 factor_taskd"
    echo -e "  ${BLUE}restart${NC}   重启 factor_taskd"
    echo -e "  ${BLUE}status${NC}    查看状态"
    echo -e "  ${CYAN}logs${NC}      查看实时日志"
    echo -e "\n${GREEN}环境变量:${NC}"
    echo -e "  ${CYAN}FTD_HOST${NC}   监听地址 (默认: $DEFAULT_HOST)"
    echo -e "  ${CYAN}FTD_PORT${NC}   监听端口 (默认: $DEFAULT_PORT)"
    echo -e "\n${GREEN}示例:${NC}"
    echo -e "  $0 start          # 启动守护进程"
    echo -e "  $0 status          # 查看状态"
    echo -e "  $0 logs            # 查看日志"
}

case "$1" in
    start)   start_service ;;
    stop)    stop_service ;;
    restart) restart_service ;;
    status)  print_status ;;
    logs)    show_logs ;;
    help|--help|-h) show_help ;;
    *) show_help; exit 1 ;;
esac
