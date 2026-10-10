#!/usr/bin/env python3
"""Analyze a private maintenance snapshot on Mac; never execute ADB or repairs."""

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
MAX_FILE_BYTES = 16 * 1024 * 1024
COMMANDS = ("memory", "data_storage", "packages_installed", "packages_enabled",
            "packages_disabled", "home_version")
PACKAGES = (
    ("com.google.android.tvlauncher", "Штатный HOME", True),
    ("com.metzrevive.home", "METZ Home", True),
    ("com.kick.mobile", "Kick", True),
    ("dev.vodik7.atvtoolsserver", "atvTools", True),
    ("com.aengix.tvbrowser", "No BS Browser", True),
    ("com.phlox.tvwebbrowser", "TV Bro (возврат)", True),
    ("com.google.android.apps.mediashell", "Штатный Cast", True),
    ("com.google.android.tvrecommendations", "Recommendations", False),
    ("tv.anoki.acr.controller", "Anoki", False),
)


def successful(result):
    return (isinstance(result, dict) and type(result.get("returncode")) is int
            and result["returncode"] == 0 and result.get("timed_out") is False
            and result.get("truncated") is False and isinstance(result.get("stdout"), str)
            and len(result["stdout"]) <= 262144 and isinstance(result.get("stderr"), str)
            and not result["stderr"].strip())


def memory_value(output, key):
    values = re.findall(r"^" + key + r":\s+(\d{1,12})\s+kB\s*$", output, re.M)
    return int(values[0]) if len(values) == 1 else None


def storage_values(output):
    if not re.search(r"^Filesystem\s+1K-blocks\s+Used\s+Available\s+Use%\s+Mounted on\s*$", output, re.M):
        return None
    rows = []
    for line in output.splitlines():
        fields = line.split()
        # This TV reports /data/user/0 as the mount for the fixed `df -k /data` query.
        if len(fields) == 6 and fields[-1] in {"/data", "/data/user/0"}:
            if not all(re.fullmatch(r"\d{1,12}", field) for field in fields[1:4]):
                return None
            if not re.fullmatch(r"\d{1,3}%", fields[4]):
                return None
            total, used, available = map(int, fields[1:4])
            if total <= 0 or used > total or available > total or used + available > total:
                return None
            rows.append({"total_kib": total, "used_kib": used, "available_kib": available})
    return rows[0] if len(rows) == 1 else None


def package_list(output):
    lines = output.splitlines()
    # Android's own package is named `android`, without a dot.
    if any(not re.fullmatch(r"package:[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*", line) for line in lines):
        return None
    return {line[8:] for line in lines}


def build_report(snapshot):
    if not isinstance(snapshot, dict) or snapshot.get("profile") != "maintenance":
        raise ValueError("requires a maintenance snapshot")
    results = snapshot.get("results")
    if not isinstance(results, dict) or not results or not set(results).issubset(COMMANDS):
        raise ValueError("invalid maintenance commands")
    complete = (snapshot.get("collection_complete") is True
                and type(snapshot.get("expected_commands")) is int
                and snapshot["expected_commands"] == len(COMMANDS) and set(results) == set(COMMANDS))
    outputs = {key: result["stdout"] for key, result in results.items() if successful(result)}
    statuses = [{"command": key, "status": "available" if key in outputs else
                 ("limited" if key in results else "not_collected")} for key in COMMANDS]
    memory = outputs.get("memory", "")
    total = memory_value(memory, "MemTotal")
    available = memory_value(memory, "MemAvailable")
    if total is None or total <= 0 or available is None or available > total:
        total = available = None
    storage = storage_values(outputs.get("data_storage", ""))
    lists = {name: package_list(outputs[name]) if name in outputs else None for name in
             ("packages_installed", "packages_enabled", "packages_disabled")}
    if not lists["packages_installed"]:
        lists["packages_installed"] = None
    packages = []
    recommendations = []
    for package, title, protected in PACKAGES:
        state = "unknown"
        installed, enabled, disabled = (lists[key] for key in lists)
        if installed is not None:
            if package not in installed:
                if enabled is not None and disabled is not None and package not in enabled and package not in disabled:
                    state = "absent"
            elif enabled is not None and disabled is not None:
                if package in enabled and package not in disabled:
                    state = "enabled"
                elif package in disabled and package not in enabled:
                    state = "disabled"
        packages.append({"name": title, "state": state})
        if protected and state in {"absent", "disabled"}:
            recommendations.append(f"{title}: проверить вручную доступность и журнал изменений перед любым восстановлением.")
        if package == "com.google.android.tvrecommendations" and state == "enabled":
            recommendations.append("Recommendations включён: сверить с согласованной пачкой; автоматическое отключение не выполняется.")
    versions = re.findall(r"^\s*versionName=(\d{1,6}\.\d{1,6}\.\d{1,6})\s*$",
                          outputs.get("home_version", ""), re.M)
    version = versions[0] if len(versions) == 1 else None
    timestamp = None
    try:
        parsed = datetime.fromisoformat(snapshot.get("started_utc", ""))
        if parsed.tzinfo is not None:
            timestamp = parsed.isoformat()
    except (ValueError, TypeError):
        pass
    if storage and storage["available_kib"] == 0:
        recommendations.append("На /data нет доступного места: проверить данные вручную; ничего не удалять автоматически.")
    unrecognized = []
    if "memory" in outputs and total is None:
        unrecognized.append("memory")
    if "data_storage" in outputs and storage is None:
        unrecognized.append("data_storage")
    if all(key in outputs for key in lists) and any(item["state"] == "unknown" for item in packages):
        unrecognized.append("packages")
    if "home_version" in outputs and version is None:
        unrecognized.append("home_version")
    if not complete or len(outputs) < len(COMMANDS) or unrecognized:
        recommendations.append("Сбор неполный или ограничен: отсутствующие факты не считать нормальным состоянием; повторить запрос после проверки доступа.")
    recommendations.append("Звук после сна, управление, браузер и реальный Cast проверить по финальному ручному чек-листу.")
    return {"schema_version": 1, "snapshot_utc": timestamp, "collection_complete": complete,
            "commands": statuses, "unrecognized_fields": unrecognized,
            "memory": {"total_kib": total, "available_kib": available},
            "data_storage": storage, "home_version": version, "packages": packages,
            "recommendations": recommendations,
            "limitations": ["Один срез не подтверждает стабильность, скорость, исправность звука или величину энергопотребления.",
                            "Enabled означает состояние пакета для user 0; запуск, HOME по умолчанию, alias и код override не проверены.",
                            "Автозапуск, очистка, перезагрузка и изменения настроек не выполняются."]}


def markdown(report):
    states = {"enabled": "включён", "disabled": "отключён", "absent": "не установлен", "unknown": "не подтверждено"}
    def number(value):
        return "нет подтверждённых данных" if value is None else f"{value:,} КиБ".replace(",", " ")
    lines = ["# METZ — обслуживание по запросу", "",
             "Полнота сбора: " + ("завершён" if report["collection_complete"] else "неполный"),
             "Команд без ошибок/timeout/обрезки: " + str(sum(item["status"] == "available" for item in report["commands"])) + "/6", ""]
    if report["unrecognized_fields"]:
        lines += ["Нераспознанные данные: " + ", ".join(report["unrecognized_fields"]), ""]
    if report["snapshot_utc"]:
        lines += ["Время снимка: " + report["snapshot_utc"], ""]
    lines += ["Android RAM: " + number(report["memory"]["total_kib"]),
              "MemAvailable: " + number(report["memory"]["available_kib"]),
              "Доступно на /data: " + number((report["data_storage"] or {}).get("available_kib")),
              "Версия METZ Home: " + (report["home_version"] or "не подтверждена"), "",
              "| Пакет | Состояние user 0 |", "|---|---|"]
    lines += [f"| {item['name']} | {states[item['state']]} |" for item in report["packages"]]
    lines += ["", "## Следующие проверки", ""]
    lines += ["- " + item for item in report["recommendations"]]
    lines += ["", "## Ограничения", ""]
    lines += ["- " + item for item in report["limitations"]]
    return "\n".join(lines) + "\n"


def load_snapshot(path):
    folder = (ROOT / "local" / "diagnostics").resolve()
    # Do not follow file symlinks or accept raw files outside the project's private folder.
    if path.is_symlink() or path.resolve().parent != folder or not path.is_file():
        raise ValueError("snapshot must be a regular file in local/diagnostics")
    with path.open("rb") as source:
        data = source.read(MAX_FILE_BYTES + 1)
    if len(data) > MAX_FILE_BYTES:
        raise ValueError("snapshot exceeds size limit")
    return json.loads(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", type=Path)
    parser.add_argument("--format", choices=("json", "markdown"), default="markdown")
    parser.add_argument("--output", type=Path, help="New report file; never overwrites an existing report")
    args = parser.parse_args()
    try:
        report = build_report(load_snapshot(args.snapshot))
    except (ValueError, OSError, TypeError, RecursionError):
        parser.error("invalid, unreadable or unsupported snapshot; raw content is not printed")
    content = markdown(report) if args.format == "markdown" else json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        try:
            descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as destination:
                destination.write(content)
        except OSError:
            parser.error("report cannot be created; existing files are preserved")
    else:
        print(content, end="")


if __name__ == "__main__":
    main()
