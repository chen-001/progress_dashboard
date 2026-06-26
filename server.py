#!/usr/bin/env python3
"""run_pools_queue 进度总控监控 Dashboard

常驻运行，自动扫描 /home/chenzongwei/pythoncode 下的 backup_*.bin.progress.jsonl 文件，
提供 Web Dashboard 展示历史运行和实时监控。

启动方式：
    python server.py --port 8080
"""

import glob
import json
import os
import argparse
import asyncio
from statistics import mean, median
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse
from jinja2 import Environment, FileSystemLoader

WATCH_DIR = "/home/chenzongwei/pythoncode"
PATTERN = "backup_*.bin.progress.jsonl"

app = FastAPI()
templates = Environment(loader=FileSystemLoader(Path(__file__).parent / "templates"))

# ==================== 数据模型 ====================


def parse_jsonl(filepath: str) -> dict:
    """解析一个 JSONL 文件，返回 {run_id: {records, status, meta}} 的分组结构"""
    runs = {}
    run_order = []
    try:
        with open(filepath) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                run_id = record.get("run_id", "unknown")
                if run_id not in runs:
                    runs[run_id] = {"records": [], "status": "running", "meta": {}}
                    run_order.append(run_id)
                if record.get("status") == "started":
                    runs[run_id]["meta"] = {
                        "total_batches": record.get("total_batches", 0),
                        "total_tasks": record.get("total_tasks", 0),
                        "total_dates": record.get("total_dates", 0),
                        "backup_batch_size": record.get("backup_batch_size", 0),
                        "start_ts": record.get("ts", ""),
                    }
                elif record.get("status") == "completed":
                    runs[run_id]["status"] = "completed"
                    runs[run_id]["meta"]["end_ts"] = record.get("ts", "")
                    runs[run_id]["meta"]["total_collected"] = record.get(
                        "total_collected", 0
                    )
                    runs[run_id]["meta"]["total_batches_done"] = record.get(
                        "total_batches_done", 0
                    )
                else:
                    runs[run_id]["records"].append(record)
    except FileNotFoundError:
        pass
    return runs, run_order


def build_jobs(filepath: str) -> list[dict]:
    """将同一 backup 文件的多个 run_id 合并为 job（断点续传时累加）

    规则：如果一个 run 没有 completed 标记（被中断），它与下一个 run 属于同一个 job。
    """
    runs, run_order = parse_jsonl(filepath)
    if not run_order:
        return []

    jobs = []
    current_job_runs = [run_order[0]]

    for i in range(1, len(run_order)):
        prev_id = run_order[i - 1]
        # 如果前一个 run 被中断（没有 completed），则合并到同一个 job
        if runs[prev_id]["status"] != "completed":
            current_job_runs.append(run_order[i])
        else:
            jobs.append(current_job_runs)
            current_job_runs = [run_order[i]]
    jobs.append(current_job_runs)

    result = []
    for job_runs in jobs:
        # 合并所有 run 的记录，累加 elapsed
        all_records = []
        cumulative_elapsed_offset = 0.0
        cumulative_batch_offset = 0
        cumulative_collected_offset = 0
        cumulative_elapsed_before_last_run = 0.0
        cumulative_batch_before_last_run = 0
        cumulative_collected_before_last_run = 0
        first_run = runs[job_runs[0]]
        last_run = runs[job_runs[-1]]
        is_running = last_run["status"] == "running"

        for idx, rid in enumerate(job_runs):
            if idx == len(job_runs) - 1:
                cumulative_batch_before_last_run = cumulative_batch_offset
                cumulative_collected_before_last_run = cumulative_collected_offset
                cumulative_elapsed_before_last_run = cumulative_elapsed_offset
            run_data = runs[rid]
            for r in run_data["records"]:
                adjusted = dict(r)
                adjusted["batch"] = r.get("batch", 0) + cumulative_batch_offset
                adjusted["collected"] = (
                    r.get("collected", 0) + cumulative_collected_offset
                )
                adjusted["elapsed"] = r.get("elapsed", 0) + cumulative_elapsed_offset
                all_records.append(adjusted)
            # 累加偏移量（用最后一次备份的数据）
            if run_data["records"]:
                last_rec = run_data["records"][-1]
                cumulative_batch_offset += last_rec.get("batch", 0)
                cumulative_collected_offset += last_rec.get("collected", 0)
                cumulative_elapsed_offset += last_rec.get("elapsed", 0)

        # 计算合并后的 total_batches：用最后一个 run 的 total_batches + 累计批次偏移
        last_meta = last_run["meta"]
        first_meta = first_run["meta"]
        # 总批次 = 之前完成的批次 + 最后一次运行预估的总批次
        total_batches = cumulative_batch_before_last_run + last_meta.get(
            "total_batches", 0
        )

        # 任务完成时，用 completed 记录生成一条合成最终记录
        if not is_running and last_meta.get("end_ts") and all_records:
            prev_rec = all_records[-1]
            end_ts = last_meta["end_ts"]
            start_ts = first_meta.get("start_ts", "")
            elapsed = 0.0
            if start_ts:
                from datetime import datetime

                try:
                    elapsed = (
                        datetime.fromisoformat(end_ts)
                        - datetime.fromisoformat(start_ts)
                    ).total_seconds()
                except ValueError:
                    elapsed = prev_rec.get("elapsed", 0)
            if elapsed <= 0:
                elapsed = prev_rec.get("elapsed", 0)
            batch_done = last_meta.get("total_batches_done", 0)
            if batch_done <= 0:
                batch_done = total_batches
            total_elapsed = cumulative_elapsed_before_last_run + elapsed
            all_records.append(
                {
                    "batch": cumulative_batch_before_last_run + batch_done,
                    "collected": cumulative_collected_before_last_run
                    + last_meta.get("total_collected", 0),
                    "elapsed": total_elapsed,
                    "interval": total_elapsed - prev_rec.get("elapsed", 0),
                    "ts": end_ts,
                }
            )

        job_id = "+".join(job_runs)  # 合并后的 job 标识
        result.append(
            {
                "job_id": job_id,
                "run_ids": job_runs,
                "records": all_records,
                "status": last_run["status"],
                "is_running": is_running,
                "meta": {**first_meta, "total_batches": total_batches},
                "n_runs": len(job_runs),
            }
        )
    return result


def scan_all_runs() -> list[dict]:
    """扫描所有 JSONL 文件，返回运行摘要列表"""
    pattern = os.path.join(WATCH_DIR, "**", PATTERN)
    files = glob.glob(pattern, recursive=True)
    all_runs = []
    for filepath in files:
        backup_name = filepath.replace(".progress.jsonl", "").split("/")[-1]
        display_name = backup_name.removeprefix("backup_").removesuffix(".bin")
        jobs = build_jobs(filepath)
        for job in jobs:
            records = job["records"]
            meta = job["meta"]
            last_record = records[-1] if records else {}
            batch_count = last_record.get("batch", 0)
            total_batches = meta.get("total_batches", 0)
            elapsed = last_record.get("elapsed", 0)
            collected = last_record.get("collected", 0)
            total_tasks = meta.get("total_tasks", 0) or meta.get("total_dates", 0)
            progress = batch_count / total_batches if total_batches > 0 else 0
            throughput = collected / elapsed if elapsed > 0 else 0
            intervals = [r["interval"] for r in records if "interval" in r]
            etas = (
                compute_etas(intervals, total_batches - batch_count)
                if total_batches > batch_count
                else {}
            )
            all_runs.append(
                {
                    "run_id": job["job_id"],
                    "backup_file": display_name,
                    "status": job["status"],
                    "is_running": job["is_running"],
                    "progress": min(progress, 1.0),
                    "batch_count": batch_count,
                    "total_batches": total_batches,
                    "collected": collected,
                    "total_tasks": total_tasks,
                    "elapsed": elapsed,
                    "throughput": throughput,
                    "etas": etas,
                    "start_ts": meta.get("start_ts", ""),
                    "end_ts": meta.get("end_ts", ""),
                    "last_backup_ts": last_record.get("ts", ""),
                    "filepath": filepath,
                    "total_dates": meta.get("total_dates", 0),
                    "completed_dates": last_record.get("completed_dates", 0),
                    "n_intervals": len(intervals),
                    "n_runs": job["n_runs"],
                }
            )
    all_runs.sort(key=lambda x: x["start_ts"], reverse=True)
    return all_runs


# ==================== ETA 估算引擎 ====================


def compute_etas(intervals: list[float], remaining_batches: int) -> dict:
    """4 种 ETA 估算算法"""
    if not intervals or remaining_batches <= 0:
        return {}
    global_avg = mean(intervals) * remaining_batches
    window_5 = mean(intervals[-5:]) * remaining_batches if len(intervals) >= 1 else 0
    alpha = 0.3
    ewma_val = intervals[0]
    for iv in intervals[1:]:
        ewma_val = alpha * iv + (1 - alpha) * ewma_val
    ewma_est = ewma_val * remaining_batches
    recent = intervals[-20:] if len(intervals) >= 20 else intervals
    median_est = median(recent) * remaining_batches
    return {
        "global_avg": round(global_avg, 1),
        "window_5": round(window_5, 1),
        "ewma": round(ewma_est, 1),
        "median": round(median_est, 1),
    }


# ==================== API 路由 ====================


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    template = templates.get_template("index.html")
    # no-store：HTML 内联了 JS，必须每次拉取最新版本，
    # 否则浏览器缓存旧版（含旧 bug 的 JS），更新后用户不硬刷新就拿不到新代码。
    return HTMLResponse(
        template.render(), headers={"Cache-Control": "no-store, must-revalidate"}
    )


@app.get("/api/runs")
async def api_runs():
    return JSONResponse(scan_all_runs())


@app.get("/api/runs/{run_id}")
async def api_run_detail(run_id: str):
    """获取某次运行的完整数据，用于图表渲染"""
    pattern = os.path.join(WATCH_DIR, "**", PATTERN)
    files = glob.glob(pattern, recursive=True)
    for filepath in files:
        jobs = build_jobs(filepath)
        for job in jobs:
            if job["job_id"] == run_id:
                records = job["records"]
                intervals = [r["interval"] for r in records if "interval" in r]
                batches = [r["batch"] for r in records if "batch" in r]
                elapsed_list = [r["elapsed"] for r in records if "elapsed" in r]
                collected_list = [r["collected"] for r in records if "collected" in r]
                timestamps = [r.get("ts", "") for r in records]
                total_batches = job["meta"].get("total_batches", 0)
                eta_series = {
                    "global_avg": [],
                    "window_5": [],
                    "ewma": [],
                    "median": [],
                }
                for i in range(len(intervals)):
                    remaining = total_batches - batches[i] if i < len(batches) else 0
                    etas = compute_etas(intervals[: i + 1], remaining)
                    for key in eta_series:
                        eta_series[key].append(etas.get(key, 0))
                throughput_list = [
                    round(collected_list[i] / elapsed_list[i], 1)
                    if i < len(elapsed_list) and elapsed_list[i] > 0
                    else 0
                    for i in range(len(collected_list))
                ]
                batch_size = job["meta"].get("backup_batch_size", 0)
                instant_throughput = [
                    round(batch_size / iv, 1) if iv > 0 and batch_size > 0 else 0
                    for iv in intervals
                ]
                return JSONResponse(
                    {
                        "run_id": run_id,
                        "status": job["status"],
                        "filepath": filepath,
                        "meta": job["meta"],
                        "intervals": intervals,
                        "batches": batches,
                        "elapsed": elapsed_list,
                        "collected": collected_list,
                        "throughput": throughput_list,
                        "instant_throughput": instant_throughput,
                        "timestamps": timestamps,
                        "eta_series": eta_series,
                        "total_batches": total_batches,
                        "n_runs": job["n_runs"],
                    }
                )
    return JSONResponse({"error": "run not found"}, status_code=404)


@app.get("/api/runs/{run_id}/latest")
async def api_run_latest(run_id: str):
    """获取最新一条记录，用于轮询刷新"""
    pattern = os.path.join(WATCH_DIR, "**", PATTERN)
    files = glob.glob(pattern, recursive=True)
    for filepath in files:
        jobs = build_jobs(filepath)
        for job in jobs:
            if job["job_id"] == run_id:
                records = job["records"]
                last = records[-1] if records else {}
                intervals = [r["interval"] for r in records if "interval" in r]
                batch_count = last.get("batch", 0)
                total_batches = job["meta"].get("total_batches", 0)
                etas = (
                    compute_etas(intervals, total_batches - batch_count)
                    if total_batches > batch_count
                    else {}
                )
                return JSONResponse(
                    {
                        "status": job["status"],
                        "last_record": last,
                        "etas": etas,
                        "batch_count": batch_count,
                        "total_batches": total_batches,
                        "n_records": len(records),
                    }
                )
    return JSONResponse({"error": "run not found"}, status_code=404)


@app.delete("/api/runs/{run_id}")
async def api_delete_run(run_id: str):
    """删除指定 run/job 的所有记录（从 JSONL 文件中移除）"""
    # run_id 可能是 job_id（多个 run_id 用 + 拼接），也可能是单个 run_id
    run_ids_to_remove = set(run_id.split("+"))

    # 找到该 run 所在的文件
    pattern = os.path.join(WATCH_DIR, "**", PATTERN)
    files = glob.glob(pattern, recursive=True)
    target_file = None
    for filepath in files:
        jobs = build_jobs(filepath)
        for job in jobs:
            if job["job_id"] == run_id:
                target_file = filepath
                break
        if target_file:
            break

    if not target_file:
        return JSONResponse({"error": "run not found"}, status_code=404)

    # 读取原文件，过滤掉需要删除的 run_id
    remaining_lines = []
    removed_count = 0
    try:
        with open(target_file, "r", encoding="utf-8") as f:
            for line in f:
                line_stripped = line.strip()
                if not line_stripped:
                    continue
                try:
                    record = json.loads(line_stripped)
                except json.JSONDecodeError:
                    remaining_lines.append(line)
                    continue
                if record.get("run_id") in run_ids_to_remove:
                    removed_count += 1
                else:
                    remaining_lines.append(line)
    except FileNotFoundError:
        return JSONResponse({"error": "file not found"}, status_code=404)

    # 写回文件
    with open(target_file, "w", encoding="utf-8") as f:
        f.writelines(remaining_lines)

    return JSONResponse(
        {
            "status": "ok",
            "message": f"已删除 {removed_count} 条记录",
            "removed": removed_count,
            "filepath": target_file,
        }
    )


# ==================== 因子任务管理代理路由 ====================
TASK_DAEMON_URL = os.environ.get("FACTOR_TASK_URL", "http://127.0.0.1:9099")


def _proxy_to_daemon(
    path: str, method: str = "GET", body: dict | None = None
) -> dict | list:
    """将请求代理到 factor_taskd 守护进程（同步阻塞，必须经 to_thread 调用）"""
    import urllib.request

    url = f"{TASK_DAEMON_URL}{path}"
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.loads(resp.read().decode())
    except OSError:
        # 涵盖 URLError / HTTPError / ConnectionRefusedError / TimeoutError。
        # daemon 偶发慢响应时 urlopen 抛 TimeoutError，必须在此吞掉，
        # 否则逃逸为 ASGI 异常导致连接异常关闭、浏览器连接池耗尽而卡死。
        return {"error": "factor_taskd 未运行"}


async def _proxy_json(
    path: str, method: str = "GET", body: dict | None = None
) -> JSONResponse:
    """异步代理：在线程池执行同步 urllib 调用，避免阻塞事件循环。

    daemon 慢响应时单个请求最多阻塞线程池 5s（timeout），但事件循环
    不受影响，其他请求（含关闭弹窗等前端交互）仍可正常响应。
    """
    result = await asyncio.to_thread(_proxy_to_daemon, path, method, body)
    return JSONResponse(result, headers={"Cache-Control": "no-store"})


@app.get("/api/tasks")
async def proxy_list_tasks():
    return await _proxy_json("/api/tasks")


@app.post("/api/tasks")
async def proxy_submit_task(request: Request):
    body = await request.json()
    return await _proxy_json("/api/tasks", "POST", body)


@app.get("/api/tasks/{task_id}")
async def proxy_get_task(task_id: int):
    return await _proxy_json(f"/api/tasks/{task_id}")


@app.post("/api/tasks/{task_id}/cancel")
async def proxy_cancel_task(task_id: int):
    return await _proxy_json(f"/api/tasks/{task_id}/cancel", "POST")


@app.post("/api/tasks/{task_id}/adjust-njobs")
async def proxy_adjust_njobs(task_id: int, request: Request):
    body = await request.json()
    return await _proxy_json(f"/api/tasks/{task_id}/adjust-njobs", "POST", body)


@app.get("/api/tasks/{task_id}/log")
async def proxy_get_task_log(task_id: int, request: Request):
    query = str(request.query_params)
    path = f"/api/tasks/{task_id}/log"
    if query:
        path += "?" + query
    return await _proxy_json(path)


@app.get("/api/tasks/{task_id}/subprocess-log")
async def proxy_get_subprocess_log(task_id: int, request: Request):
    query = str(request.query_params)
    path = f"/api/tasks/{task_id}/subprocess-log"
    if query:
        path += "?" + query
    return await _proxy_json(path)


# ==================== 启动入口 ====================

if __name__ == "__main__":
    import uvicorn

    parser = argparse.ArgumentParser(description="run_pools_queue 进度总控监控")
    parser.add_argument("--port", type=int, default=8080, help="服务端口")
    parser.add_argument("--host", type=str, default="0.0.0.0", help="服务地址")
    args = parser.parse_args()
    print(f"🚀 进度监控 Dashboard 启动: http://{args.host}:{args.port}")
    print(f"📁 监控目录: {WATCH_DIR}")
    uvicorn.run(app, host=args.host, port=args.port)
