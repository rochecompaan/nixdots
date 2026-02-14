import argparse
import json
import os
import pathlib
import subprocess
import sys
import time
from datetime import datetime, timezone

from rich.console import Console
from rich.markdown import Markdown
from rich.rule import Rule


def rel(delta):
    secs = int(delta.total_seconds())
    if secs < 60:
        return f"{secs}s ago"
    mins = secs // 60
    if mins < 60:
        return f"{mins}m ago"
    hours = mins // 60
    if hours < 24:
        return f"{hours}h ago"
    days = hours // 24
    if days < 30:
        return f"{days}d ago"
    months = days // 30
    if months < 12:
        return f"{months}mo ago"
    years = months // 12
    return f"{years}y ago"


def load_session_index(root):
    out = {}
    if not root.exists():
        return out
    for path in root.rglob("*.jsonl"):
        sid = None
        cwd = None
        try:
            with path.open() as f:
                for line in f:
                    if not line.strip():
                        continue
                    try:
                        obj = json.loads(line)
                    except Exception:
                        continue
                    if obj.get("type") == "session_meta":
                        payload = obj.get("payload") or {}
                        sid = payload.get("id")
                        cwd = payload.get("cwd")
                        break
        except Exception:
            continue
        if sid:
            out[sid] = {"cwd": cwd or "", "path": path}
    return out


def codex_roots():
    roots = []
    env_root = os.environ.get("CODEX_HOME")
    if env_root:
        roots.append(pathlib.Path(env_root).expanduser())

    default_root = pathlib.Path.home() / ".codex"
    if default_root not in roots:
        roots.append(default_root)

    return roots


def build_sessions():
    sessions = {}
    roots = codex_roots()
    history_paths = [root / "history.jsonl" for root in roots]
    sessions_roots = [root / "sessions" for root in roots]

    session_index = {}
    for sessions_root in sessions_roots:
        for sid, data in load_session_index(sessions_root).items():
            if sid not in session_index:
                session_index[sid] = data

    for history in history_paths:
        if not history.exists():
            continue
        with history.open() as f:
            for line in f:
                if not line.strip():
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                sid = obj.get("session_id")
                ts = obj.get("ts")
                text = obj.get("text") or ""
                if not sid or not ts:
                    continue
                title = text.strip().splitlines()[0] if text else ""
                title = (title[:80] + "...") if len(title) > 80 else (title or "Untitled")
                prev = sessions.get(sid)
                if not prev or ts > prev[0]:
                    sessions[sid] = (ts, title)

    rows = []
    for sid, (ts, title) in sessions.items():
        meta = session_index.get(sid, {})
        rows.append((ts, title, sid, meta.get("cwd", ""), meta.get("path")))
    rows.sort(key=lambda x: x[0], reverse=True)
    return rows, sessions_roots


def print_list(rows, limit):
    now = datetime.now(timezone.utc)
    first = True
    for ts, title, sid, cwd, _path in rows[:limit]:
        last_ts = datetime.fromtimestamp(ts, tz=timezone.utc)
        if not first:
            print("---")
        first = False
        print(f"{title}. {rel(now - last_ts)}")
        print(f"session id: {sid}")
        print(f"path: {cwd or '..'}")


def pick_session(rows):
    now = datetime.now(timezone.utc)
    lines = []
    for ts, title, sid, _cwd, _path in rows:
        last_ts = datetime.fromtimestamp(ts, tz=timezone.utc)
        lines.append(f"{title}. {rel(now - last_ts)}\t{sid}")
    if not lines:
        return None
    try:
        proc = subprocess.run(
            ["fzf", "--prompt", "session> ", "--with-nth", "1", "--delimiter", "\t"],
            input="\n".join(lines),
            text=True,
            capture_output=True,
            check=False,
        )
    except FileNotFoundError:
        print("fzf is required for interactive selection.", file=sys.stderr)
        return None
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    selected = proc.stdout.strip()
    parts = selected.split("\t", 1)
    return parts[1] if len(parts) == 2 else None


def parse_ts(ts):
    if not ts:
        return ""
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).strftime("%H:%M")
    except Exception:
        return ""


def format_message(role, text, ts):
    if not text:
        return None
    name = "Me" if role == "user" else "Codex"
    time_label = parse_ts(ts)
    label = f"{name} {time_label}".strip()
    color = "cyan" if name == "Me" else "magenta"
    header = Rule(f"[bold {color}]{label}[/]")
    body = Markdown(text.rstrip())
    return header, body


def parse_message(obj):
    if obj.get("type") != "response_item":
        return None
    payload = obj.get("payload") or {}
    if payload.get("type") != "message":
        return None
    role = payload.get("role")
    ts = obj.get("timestamp")
    content = payload.get("content") or []
    text_parts = []
    for part in content:
        if part.get("type") in ("input_text", "output_text"):
            text_parts.append(part.get("text", ""))
    text = "\n".join([t for t in text_parts if t])
    return format_message(role, text, ts)


def follow_session(path):
    console = Console()
    try:
        with path.open() as f:
            for line in f:
                if not line.strip():
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                formatted = parse_message(obj)
                if formatted:
                    header, body = formatted
                    console.print(header)
                    console.print(body)

            f.seek(0, 2)
            while True:
                line = f.readline()
                if not line:
                    time.sleep(0.5)
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                formatted = parse_message(obj)
                if formatted:
                    header, body = formatted
                    console.print(header)
                    console.print(body)
    except KeyboardInterrupt:
        return


def find_session_path(sessions_roots, sid, known):
    if known:
        return known
    for sessions_root in sessions_roots:
        if not sessions_root.exists():
            continue
        matches = list(sessions_root.rglob(f"*{sid}*.jsonl"))
        if matches:
            return matches[0]
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--list", action="store_true", help="List recent sessions.")
    parser.add_argument("--limit", type=int, default=10, help="Number of sessions to list.")
    args = parser.parse_args()

    rows, sessions_roots = build_sessions()

    try:
        if args.list or not sys.stdout.isatty():
            print_list(rows, args.limit)
            return 0

        sid = pick_session(rows)
        if not sid:
            return 1
        index = {row[2]: row for row in rows}
        row = index.get(sid)
        path = find_session_path(sessions_roots, sid, row[4] if row else None)
        if not path:
            print("Selected session file not found.", file=sys.stderr)
            return 1
        follow_session(path)
        return 0
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
