#!/usr/bin/env python3
"""
读取 config/qt-build.yml 并输出环境变量赋值。

支持的输出格式（--format）:
  github      输出 KEY=VALUE 行，可直接追加到 $GITHUB_ENV（默认）
  bash        输出 export KEY="VALUE" 行，可被 eval 执行
  powershell  输出 $env:KEY = "VALUE" 行，可被 Invoke-Expression 执行

用法:
  # GitHub Actions 中（后续步骤可见环境变量）
  python scripts/read-config.py config/qt-build.yml >> $GITHUB_ENV

  # Bash 中即时生效
  eval "$(python3 scripts/read-config.py config/qt-build.yml --format=bash)"

  # PowerShell 中即时生效
  python scripts/read-config.py config/qt-build.yml --format=powershell | Invoke-Expression
"""
import argparse
import shlex
import sys
from pathlib import Path

# PyYAML 在 GitHub Actions 预装的 Python 中可用；本地若未安装则提示。
try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is not installed. Install with: pip install pyyaml",
          file=sys.stderr)
    sys.exit(1)


def flatten_config(cfg: dict) -> dict:
    """将嵌套的 YAML 配置展平为 KEY=VALUE 形式。

    列表以空格连接为字符串；保留原始顺序便于 shell word-split 使用。
    """
    qt_version = str(cfg.get("qt_version", ""))
    # 计算主.次 版本号（例如 6.10.2 → 6.10），用于 download.qt.io URL
    parts = qt_version.split(".")
    minor = ".".join(parts[:2]) if len(parts) >= 2 else qt_version

    source_url = str(cfg.get("qt_source_url", "")).format(
        version=qt_version, minor=minor
    )

    submodules = cfg.get("submodules", []) or []
    skip_modules = cfg.get("skip_modules", []) or []
    common_opts = cfg.get("configure_options_common", []) or []
    per_platform = cfg.get("configure_options_per_platform", {}) or {}
    cmake_common = cfg.get("cmake_extra_args_common", []) or []
    cmake_per_platform = cfg.get("cmake_extra_args_per_platform", {}) or {}
    optimization = cfg.get("optimization", {}) or {}

    def join(items):
        return " ".join(str(x) for x in items)

    return {
        "QT_VERSION": qt_version,
        "QT_MINOR": minor,
        "QT_SOURCE_URL": source_url,
        "QT_SOURCE_SHA256": str(cfg.get("qt_source_sha256", "") or ""),
        "SUBMODULES": ",".join(submodules),
        "SKIP_MODULES": ",".join(skip_modules),
        "CONFIGURE_OPTIONS_COMMON": join(common_opts),
        "CONFIGURE_OPTIONS_WINDOWS": join(per_platform.get("windows", []) or []),
        "CONFIGURE_OPTIONS_LINUX": join(per_platform.get("linux", []) or []),
        "CONFIGURE_OPTIONS_MACOS": join(per_platform.get("macos", []) or []),
        "CMAKE_EXTRA_ARGS_COMMON": join(cmake_common),
        "CMAKE_EXTRA_ARGS_WINDOWS": join(cmake_per_platform.get("windows", []) or []),
        "CMAKE_EXTRA_ARGS_LINUX": join(cmake_per_platform.get("linux", []) or []),
        "CMAKE_EXTRA_ARGS_MACOS": join(cmake_per_platform.get("macos", []) or []),
        "STRIP_DEBUG_SYMBOLS": str(optimization.get("strip_debug_symbols", False)).lower(),
        "PARALLEL_JOBS": str(optimization.get("parallel_jobs", 0)),
        "PACKAGE_NAME_TEMPLATE": str(cfg.get("package_name_template",
                                              "qt-{version}-static-{platform}")),
    }


def output_github(env: dict) -> None:
    for key, value in env.items():
        # GitHub Actions 的 $GITHUB_ENV 支持 KEY=value 形式
        # 多行值需要特殊分隔符，这里所有值都是单行，所以直接写。
        print(f"{key}={value}")


def output_bash(env: dict) -> None:
    for key, value in env.items():
        # 使用 shlex.quote 安全包装值
        print(f"export {key}={shlex.quote(str(value))}")


def output_powershell(env: dict) -> None:
    for key, value in env.items():
        # PowerShell 单引号字符串中只需将 ' 替换为 ''
        escaped = str(value).replace("'", "''")
        print(f"$env:{key} = '{escaped}'")


def main():
    parser = argparse.ArgumentParser(
        description="Read Qt build YAML config and emit env-var assignments."
    )
    parser.add_argument("config_file", help="Path to the YAML config file.")
    parser.add_argument(
        "--format", choices=["github", "bash", "powershell"],
        default="github",
        help="Output format (default: github)."
    )
    args = parser.parse_args()

    config_path = Path(args.config_file)
    if not config_path.is_file():
        print(f"ERROR: config file not found: {config_path}", file=sys.stderr)
        sys.exit(2)

    with config_path.open("r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)

    if not isinstance(cfg, dict):
        print("ERROR: top-level YAML must be a mapping", file=sys.stderr)
        sys.exit(3)

    env = flatten_config(cfg)

    if args.format == "github":
        output_github(env)
    elif args.format == "bash":
        output_bash(env)
    elif args.format == "powershell":
        output_powershell(env)


if __name__ == "__main__":
    main()
