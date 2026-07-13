#!/usr/bin/env python3
"""
Read config/qt-build.yml and emit environment variable assignments.

Supported output formats (--format):
  github      Emit KEY=VALUE lines, suitable for appending to $GITHUB_ENV
              (default).
  bash        Emit `export KEY="VALUE"` lines, suitable for `eval`.
  powershell  Emit `$env:KEY = "VALUE"` lines, suitable for Invoke-Expression.

Usage:
  # In GitHub Actions (subsequent steps see the env vars)
  python scripts/read-config.py config/qt-build.yml >> $GITHUB_ENV

  # In Bash (takes effect immediately)
  eval "$(python3 scripts/read-config.py config/qt-build.yml --format=bash)"

  # In PowerShell (takes effect immediately)
  python scripts/read-config.py config/qt-build.yml --format=powershell | Invoke-Expression
"""
import argparse
import shlex
import sys
from pathlib import Path

# PyYAML ships with the Python preinstalled on GitHub Actions runners.
# If missing locally, print a helpful error.
try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is not installed. Install with: pip install pyyaml",
          file=sys.stderr)
    sys.exit(1)


def flatten_config(cfg: dict) -> dict:
    """Flatten the nested YAML config into KEY=VALUE pairs.

    Lists of CMake options are joined with spaces so the shell can word-split
    them when consumed unquoted. Submodule names are joined with commas.
    """
    qt_version = str(cfg.get("qt_version", ""))
    # Compute major.minor (e.g. 6.10.2 -> 6.10) for the download URL.
    parts = qt_version.split(".")
    minor = ".".join(parts[:2]) if len(parts) >= 2 else qt_version

    # Use replace() not format() to leave {submodule} as-is for the build script
    url_template = str(cfg.get("submodule_url_template", ""))
    url_template = url_template.replace("{version}", qt_version)
    url_template = url_template.replace("{minor}", minor)

    submodules = cfg.get("submodules", []) or []
    common_opts = cfg.get("cmake_options_common", []) or []
    qtbase_opts = cfg.get("cmake_options_qtbase", []) or []
    qtbase_per_platform = cfg.get("cmake_options_qtbase_per_platform", {}) or {}
    optimization = cfg.get("optimization", {}) or {}

    def join(items):
        return " ".join(str(x) for x in items)

    return {
        "QT_VERSION": qt_version,
        "QT_MINOR": minor,
        "SUBMODULE_URL_TEMPLATE": url_template,
        "SUBMODULES": ",".join(submodules),
        "CMAKE_OPTIONS_COMMON": join(common_opts),
        "CMAKE_OPTIONS_QTBASE": join(qtbase_opts),
        "CMAKE_OPTIONS_QTBASE_WINDOWS": join(qtbase_per_platform.get("windows", []) or []),
        "CMAKE_OPTIONS_QTBASE_LINUX": join(qtbase_per_platform.get("linux", []) or []),
        "CMAKE_OPTIONS_QTBASE_MACOS": join(qtbase_per_platform.get("macos", []) or []),
        "STRIP_DEBUG_SYMBOLS": str(optimization.get("strip_debug_symbols", False)).lower(),
        "PARALLEL_JOBS": str(optimization.get("parallel_jobs", 0)),
        "PACKAGE_NAME_TEMPLATE": str(cfg.get("package_name_template",
                                              "qt-{version}-static-{platform}")),
    }


def output_github(env: dict) -> None:
    for key, value in env.items():
        print(f"{key}={value}")


def output_bash(env: dict) -> None:
    for key, value in env.items():
        print(f"export {key}={shlex.quote(str(value))}")


def output_powershell(env: dict) -> None:
    for key, value in env.items():
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
