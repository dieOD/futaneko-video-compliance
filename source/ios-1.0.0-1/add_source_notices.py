#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""隔離済みの動画ソースへ、対応する変更・ライセンス通知を追記する。

このツールは、既定パッチが適用された ``sources`` と、そのコピーにある
``tool/ios_video`` を対象にする。原本キットや既定パッチを探して変更する
機能は持たず、指定されたディレクトリ内の対象ファイルだけを末尾へ追記する。
"""

from __future__ import annotations

import argparse
from collections import OrderedDict
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
from typing import Iterable


# パッチの順番は build_ios_video.sh の適用順、かつ通知の表示順として固定する。
PATCH_NAMES = (
    "ffmpeg-8.1.2-minimal-config.patch",
    "ffmpeg-8.1.2-post-release-hardening.patch",
    "mpv-0.41.0-no-subtitles.patch",
    "mpv-0.41.0-shared-audio-session.patch",
    "mpv-0.41.0-local-only.patch",
)
PATCH_COMPONENTS = {
    "ffmpeg-8.1.2-minimal-config.patch": "ffmpeg",
    "ffmpeg-8.1.2-post-release-hardening.patch": "ffmpeg",
    "mpv-0.41.0-no-subtitles.patch": "mpv",
    "mpv-0.41.0-shared-audio-session.patch": "mpv",
    "mpv-0.41.0-local-only.patch": "mpv",
}

CHANGE_DATE = "2026-08-31"
PROBE_CREATE_DATE = "2026-08-31"
MP4_CREATE_DATE = "2026-09-06"
NOTICE_VERSION = "1"
LICENSE_NAME = "LGPL-2.1-or-later"

# この文字列は、別版の通知を見分けるための安定した識別子でもある。
NOTICE_MARKER = "FutaNeko変更通知"
ADDITION_MARKER = "FutaNeko追加部品通知"

ALLOWED_SOURCE_SUFFIXES = frozenset({".c", ".h", ".m"})
MESON_NAME = "meson.build"

# 既存ソース中の通常の FutaNeko 言及を誤検出しないよう、通知を示す語も
# 同じ行に限定する。出力するブロックの日本語・英語表記の両方を認識する。
_EXISTING_NOTICE_RE = re.compile(
    r"(?:FUTANEKO_SOURCE_NOTICE|FutaNeko[^\r\n]{0,160}(?:通知|notice)|"
    r"FutaNeko向けに変更)",
    re.IGNORECASE,
)
_PATCH_HEADER_RE = re.compile(rb"^\+\+\+ b/([^\t\r\n]+)(?:\t[^\r\n]*)?$")


class NoticeError(ValueError):
    """入力を安全に検証できない場合に送出するエラー。"""


def _error(message: str) -> NoticeError:
    return NoticeError(message)


def _has_control(value: str) -> bool:
    return any(ord(character) < 0x20 or ord(character) == 0x7F for character in value)


def _absolute_path(value: str | Path, label: str) -> Path:
    """CLI/API のファイルシステムパスを軽く検証し、絶対表現へ変換する。

    CLI のディレクトリは利用しやすさのため相対パスも受け入れるが、空文字と
    制御文字は拒否する。``..`` は入力の安全境界を曖昧にするため、相対パスの
    部品として現れた場合も拒否する。
    """

    if isinstance(value, Path):
        raw = str(value)
    elif isinstance(value, str):
        raw = value
    else:
        raise _error(f"{label}のパス型が不正です")
    if not raw or _has_control(raw):
        raise _error(f"{label}のパスが空または制御文字を含みます")
    path = Path(raw)
    if any(part == ".." for part in path.parts):
        raise _error(f"{label}に親ディレクトリ指定は使えません")
    return path.absolute()


def _lstat(path: Path, label: str, *, missing_ok: bool = False) -> os.stat_result:
    try:
        result = path.lstat()
    except FileNotFoundError:
        if missing_ok:
            return None  # type: ignore[return-value]
        raise _error(f"{label}が見つかりません: {path}")
    except OSError as error:
        raise _error(f"{label}を検査できません: {path}: {error}") from error
    if stat.S_ISLNK(result.st_mode):
        raise _error(f"{label}にシンボリックリンクは使えません: {path}")
    return result


def _check_ancestors(path: Path, label: str, *, allow_missing_leaf: bool = False) -> None:
    """path と全ての既存親を lstat し、リンク・特殊ファイルを拒否する。"""

    path = path.absolute()
    # Path.parents は最上位からではなく path に近い順に返る。全要素を検査し、
    # 最後に root も確認する。存在しない葉そのものだけを report 用に許可する。
    items = (path, *path.parents)
    for index, item in enumerate(items):
        is_leaf = index == 0
        result = _lstat(item, label, missing_ok=allow_missing_leaf and is_leaf)
        if result is None:
            continue
        if is_leaf:
            continue
        if not stat.S_ISDIR(result.st_mode):
            raise _error(f"{label}の親が通常ディレクトリではありません: {item}")


def _require_directory(path: Path, label: str) -> Path:
    _check_ancestors(path, label)
    result = _lstat(path, label)
    if not stat.S_ISDIR(result.st_mode):
        raise _error(f"{label}はディレクトリではありません: {path}")
    return path


def _require_regular(path: Path, label: str) -> bytes:
    _check_ancestors(path, label)
    result = _lstat(path, label)
    if not stat.S_ISREG(result.st_mode):
        raise _error(f"{label}は通常ファイルではありません: {path}")
    if result.st_nlink != 1:
        raise _error(f"{label}にハードリンクは使えません: {path}")
    try:
        return path.read_bytes()
    except OSError as error:
        raise _error(f"{label}を読み取れません: {path}: {error}") from error


def _regular_snapshot(path: Path, label: str) -> tuple[os.stat_result, bytes]:
    """通常ファイルの inode 境界と内容を同時に取り直す。"""

    _check_ancestors(path, label)
    result = _lstat(path, label)
    if not stat.S_ISREG(result.st_mode):
        raise _error(f"{label}は通常ファイルではありません: {path}")
    if result.st_nlink != 1:
        raise _error(f"{label}にハードリンクは使えません: {path}")
    try:
        return result, path.read_bytes()
    except OSError as error:
        raise _error(f"{label}を読み取れません: {path}: {error}") from error


def _optional_regular(path: Path, label: str) -> bytes | None:
    """存在しない場合だけ None、それ以外は通常ファイルとして検証する。"""

    _check_ancestors(path, label, allow_missing_leaf=True)
    result = _lstat(path, label, missing_ok=True)
    if result is None:
        return None
    if not stat.S_ISREG(result.st_mode):
        raise _error(f"{label}は通常ファイルではありません: {path}")
    if result.st_nlink != 1:
        raise _error(f"{label}にハードリンクは使えません: {path}")
    try:
        return path.read_bytes()
    except OSError as error:
        raise _error(f"{label}を読み取れません: {path}: {error}") from error


def _validate_relative_path(raw: str, label: str) -> PurePosixPath:
    """パッチヘッダの POSIX 相対パスを厳密に検証する。"""

    if not raw or _has_control(raw):
        raise _error(f"{label}が空または制御文字を含みます")
    if "\\" in raw or raw.startswith("/"):
        raise _error(f"{label}はPOSIX相対パスである必要があります")
    # PurePosixPath は Windows のドライブ文字を絶対パスと判定しないため、
    # それも明示的に弾く。コロンを含む通常のUnix名まで一律に禁止しない。
    if re.match(r"^[A-Za-z]:", raw):
        raise _error(f"{label}にドライブ指定は使えません")
    parts = raw.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise _error(f"{label}に空・`.`・`..`のパス部品があります")
    path = PurePosixPath(raw)
    if path.is_absolute() or path.as_posix() != raw:
        raise _error(f"{label}の表記が正規化済みPOSIX相対パスではありません")
    suffix = Path(parts[-1]).suffix
    if parts[-1] != MESON_NAME and suffix not in ALLOWED_SOURCE_SUFFIXES:
        raise _error(f"{label}の拡張子が対象外です: {raw}")
    return path


def _decode_patch(data: bytes, patch_name: str) -> str:
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise _error(f"パッチがUTF-8ではありません: {patch_name}") from error


def _patch_targets(patch_name: str, data: bytes) -> list[PurePosixPath]:
    """+++ b/... の一覧を取り出し、同一パッチ内の重複を拒否する。"""

    # decode を先に行って、不正UTF-8を「ヘッダが無い」と曖昧に扱わない。
    _decode_patch(data, patch_name)
    targets: list[PurePosixPath] = []
    seen: set[PurePosixPath] = set()
    for line in data.splitlines():
        if line.startswith(b"+++ "):
            match = _PATCH_HEADER_RE.fullmatch(line)
            if not match:
                raise _error(f"パッチの+++ヘッダが不正です: {patch_name}")
            try:
                raw = match.group(1).decode("utf-8")
            except UnicodeDecodeError as error:
                raise _error(f"パッチのパスがUTF-8ではありません: {patch_name}") from error
            target = _validate_relative_path(raw, f"{patch_name}: +++ b/{raw}")
            if target in seen:
                raise _error(f"パッチ内に重複する+++パスがあります: {patch_name}: {raw}")
            seen.add(target)
            targets.append(target)
    if not targets:
        raise _error(f"パッチに+++ b/ヘッダがありません: {patch_name}")
    return targets


def _read_patches(tool_dir: Path) -> OrderedDict[tuple[str, PurePosixPath], list[str]]:
    patches_dir = tool_dir / "patches"
    _require_directory(patches_dir, "patchesディレクトリ")
    try:
        children = list(patches_dir.iterdir())
    except OSError as error:
        raise _error(f"patchesディレクトリを列挙できません: {error}") from error
    allowed = set(PATCH_NAMES)
    names = {child.name for child in children}
    if names != allowed:
        extra = sorted(names - allowed)
        missing = sorted(allowed - names)
        details = []
        if missing:
            details.append(f"不足: {', '.join(missing)}")
        if extra:
            details.append(f"想定外: {', '.join(extra)}")
        raise _error("patchesディレクトリは5つの固定パッチだけを含む必要があります（" + "; ".join(details) + "）")

    result: OrderedDict[tuple[str, PurePosixPath], list[str]] = OrderedDict()
    for patch_name in PATCH_NAMES:
        path = patches_dir / patch_name
        data = _require_regular(path, f"パッチ {patch_name}")
        for relative in _patch_targets(patch_name, data):
            component = PATCH_COMPONENTS[patch_name]
            # 追加部品はパッチ対象ではない。ここを混ぜると、LGPL通知の意味と
            # パッチ由来の上流変更通知を誤って一つにできるため拒否する。
            if component == "mpv" and relative == PurePosixPath("sub/no_subtitles.c"):
                raise _error("自作追加部品を既定パッチの対象にできません")
            key = (component, relative)
            result.setdefault(key, []).append(patch_name)
    return result


def _same_or_nested(first: Path, second: Path) -> bool:
    return first == second or first in second.parents or second in first.parents


def _comment_block(lines: Iterable[str], *, meson: bool) -> bytes:
    if meson:
        body = ["# ========================================================================"]
        body.extend("# " + line if line else "#" for line in lines)
        body.append("# ========================================================================")
    else:
        body = ["/*", " * ========================================================================"]
        body.extend(" * " + line if line else " *" for line in lines)
        body.extend([" * ========================================================================", " */"])
    return ("\n".join(body) + "\n").encode("utf-8")


def _upstream_block(patch_names: list[str], relative: PurePosixPath) -> bytes:
    joined = ", ".join(patch_names)
    return _comment_block(
        (
            f"{NOTICE_MARKER}（通知版: {NOTICE_VERSION}）",
            "FutaNeko向けに変更",
            f"変更日: {CHANGE_DATE}",
            f"変更詳細: 対応する同梱patch: {joined}",
            "上流の著作権/ライセンス保持",
            f"対象: {relative.as_posix()}",
        ),
        meson=relative.name == MESON_NAME,
    )


def _addition_block(filename: str, create_date: str) -> bytes:
    return _comment_block(
        (
            f"{ADDITION_MARKER}（通知版: {NOTICE_VERSION}）",
            f"追加部品: {filename}",
            f"ライセンス: {LICENSE_NAME}（LGPL2.1+）",
            f"作成日: {create_date}（{create_date.replace('-', '')}）",
            "ライセンス根拠: 同梱 LICENSE_SCOPE.ja.md",
        ),
        meson=False,
    )


def _append_state(data: bytes, block: bytes, label: str) -> tuple[bytes, bytes, bool]:
    """(結果, 追加部分, 既存ブロックを再利用したか) を返す。"""

    text = data.decode("utf-8")
    block_text = block.decode("utf-8")
    if block in data:
        # 同じブロックが既にあれば冪等に処理する。別ブロックも同居する場合は、
        # 版の混在なので見逃さず拒否する。
        without_expected = text.replace(block_text, "")
        if _EXISTING_NOTICE_RE.search(without_expected):
            raise _error(f"異なる版または内容のFutaNeko通知があります: {label}")
        return data, b"", True
    if _EXISTING_NOTICE_RE.search(text):
        raise _error(f"異なる版または内容のFutaNeko通知があります: {label}")
    separator = b"" if data.endswith((b"\n", b"\r")) else b"\n"
    append = separator + block
    return data + append, append, False


def _digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _target_plan(
    path: Path,
    relative: str,
    block: bytes,
    date: str,
    label: str,
) -> dict[str, object]:
    snapshot, data = _regular_snapshot(path, label)
    try:
        # C/Objective-C/Mesonへの追記なので、壊れたバイナリを黙って末尾へ
        # 付けない。read_bytesの結果そのものは後で完全にプレフィックス保持する。
        data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise _error(f"対象ソースがUTF-8ではありません: {label}") from error
    after, append, skipped = _append_state(data, block, label)
    return {
        "path": path,
        "st_dev": snapshot.st_dev,
        "st_ino": snapshot.st_ino,
        "st_nlink": snapshot.st_nlink,
        "st_size": snapshot.st_size,
        "relative_path": relative,
        "sha256_before": _digest(data),
        "sha256_after": _digest(after),
        "date": date,
        "before": data,
        "after": after,
        "append": append,
        "skipped": skipped,
    }


def _validate_and_plan(source_dir: Path, tool_dir: Path) -> list[dict[str, object]]:
    source_dir = _require_directory(source_dir, "source-dir")
    tool_dir = _require_directory(tool_dir, "tool-dir")
    if _same_or_nested(source_dir, tool_dir):
        raise _error("source-dir と tool-dir は分離したディレクトリにしてください")

    patches = _read_patches(tool_dir)
    plans: list[dict[str, object]] = []
    plan_paths: set[Path] = set()
    for (component, relative), patch_names in patches.items():
        target = source_dir / component / Path(*relative.parts)
        if target in plan_paths:
            raise _error(f"通知対象が重複しています: {target}")
        plan_paths.add(target)
        plans.append(
            _target_plan(
                target,
                f"{component}/{relative.as_posix()}",
                _upstream_block(patch_names, relative),
                CHANGE_DATE,
                f"{component}/{relative.as_posix()}",
            )
        )

    custom_source = source_dir / "mpv/sub/no_subtitles.c"
    if custom_source in plan_paths:
        raise _error("自作追加部品の通知対象が重複しています")
    plan_paths.add(custom_source)
    plans.append(
        _target_plan(
            custom_source,
            "mpv/sub/no_subtitles.c",
            _addition_block("no_subtitles.c", CHANGE_DATE),
            CHANGE_DATE,
            "mpv/sub/no_subtitles.c",
        )
    )

    version_probe = tool_dir / "version_probe.c"
    if version_probe in plan_paths:
        raise _error("version_probe.cの通知対象が重複しています")
    plan_paths.add(version_probe)
    plans.append(
        _target_plan(
            version_probe,
            "version_probe.c",
            _addition_block("version_probe.c", PROBE_CREATE_DATE),
            PROBE_CREATE_DATE,
            "tool-dir/version_probe.c",
        )
    )

    mp4_export = tool_dir / "mp4_export.m"
    if _optional_regular(mp4_export, "tool-dir/mp4_export.m") is not None:
        if mp4_export in plan_paths:
            raise _error("mp4_export.mの通知対象が重複しています")
        plan_paths.add(mp4_export)
        plans.append(
            _target_plan(
                mp4_export,
                "mp4_export.m",
                _addition_block("mp4_export.m", MP4_CREATE_DATE),
                MP4_CREATE_DATE,
                "tool-dir/mp4_export.m",
            )
        )

    # 結果の順序を入力ディレクトリの列挙順に依存させない。
    plans.sort(key=lambda plan: str(plan["relative_path"]))
    return plans


def _public_report(plans: list[dict[str, object]]) -> list[dict[str, str]]:
    return [
        {
            "relative_path": str(plan["relative_path"]),
            "sha256_before": str(plan["sha256_before"]),
            "sha256_after": str(plan["sha256_after"]),
            "date": str(plan["date"]),
        }
        for plan in plans
    ]


def _snapshot_matches(plan: dict[str, object], snapshot: os.stat_result, data: bytes) -> bool:
    return (
        snapshot.st_dev == plan["st_dev"]
        and snapshot.st_ino == plan["st_ino"]
        and snapshot.st_nlink == plan["st_nlink"] == 1
        and snapshot.st_size == plan["st_size"] == len(data)
        and data == plan["before"]
        and _digest(data) == plan["sha256_before"]
    )


def _recheck_plans(plans: list[dict[str, object]]) -> None:
    """追記直前に、計画時の全通常ファイルが同じかを確認する。"""

    for plan in plans:
        path = Path(plan["path"])
        snapshot, data = _regular_snapshot(path, str(plan["relative_path"]))
        if not _snapshot_matches(plan, snapshot, data):
            raise _error(f"計画後に対象が変更されました: {path}")


def _append_file(plan: dict[str, object]) -> None:
    path = Path(plan["path"])
    append = plan["append"]
    if not append:
        return
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    if not nofollow:
        raise _error("O_NOFOLLOWを利用できる環境が必要です")
    flags = os.O_WRONLY | os.O_APPEND | nofollow
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise _error(f"通知を書き込めません: {path}: {error}") from error
    try:
        current = os.fstat(descriptor)
        # lstat+内容再検査を通った後にも inode を再確認する。O_APPEND は
        # offsetを常に末尾へ固定し、O_NOFOLLOWは競合時のリンク追従を防ぐ。
        if not stat.S_ISREG(current.st_mode) or current.st_nlink != 1:
            raise _error(f"追記対象が通常ファイルではありません: {path}")
        if not (
            current.st_dev == plan["st_dev"]
            and current.st_ino == plan["st_ino"]
            and current.st_nlink == plan["st_nlink"] == 1
            and current.st_size == plan["st_size"] == len(plan["before"])
        ):
            raise _error(f"追記直前に対象が変更されました: {path}")
        remaining = memoryview(append)
        while remaining:
            count = os.write(descriptor, remaining)
            if count <= 0:
                raise _error(f"通知を書き込めません: {path}")
            remaining = remaining[count:]
    except OSError as error:
        raise _error(f"通知を書き込めません: {path}: {error}") from error
    finally:
        os.close(descriptor)


def apply_notices(source_dir: str | Path, tool_dir: str | Path) -> list[dict[str, str]]:
    """隔離コピーへ通知を追記し、対象ごとの変更ハッシュを返す。

    ``source_dir`` には既定5パッチ適用後の ``mpv`` と ``ffmpeg`` が必要で、
    ``tool_dir`` には厳密な5パッチ、``version_probe.c`` が必要である。
    ``mp4_export.m`` は存在する版だけが対象になる。入力検証と通知版の確認を
    全対象について済ませてから、変更が必要なファイルへ書き込む。
    """

    source = _absolute_path(source_dir, "source-dir")
    tool = _absolute_path(tool_dir, "tool-dir")
    plans = _validate_and_plan(source, tool)
    # 1件でも別プロセス等に変更されていれば、この実行では一切追記を始めない。
    _recheck_plans(plans)
    for plan in plans:
        if not plan["skipped"]:
            _append_file(plan)
    return _public_report(plans)


def _validate_report_path(value: str | Path) -> Path:
    report = _absolute_path(value, "report")
    _check_ancestors(report, "report", allow_missing_leaf=True)
    result = _lstat(report, "report", missing_ok=True)
    if result is not None:
        raise _error(f"reportは新規パスである必要があります: {report}")
    parent = report.parent
    parent_result = _lstat(parent, "reportの親")
    if not stat.S_ISDIR(parent_result.st_mode):
        raise _error(f"reportの親が通常ディレクトリではありません: {parent}")
    return report


def _write_report(path: Path, report: list[dict[str, str]]) -> None:
    payload = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    try:
        # 事前検査後にも既存化する競合を上書きしない。
        with path.open("x", encoding="utf-8", newline="\n") as stream:
            stream.write(payload)
    except FileExistsError as error:
        raise _error(f"reportは新規パスである必要があります: {path}") from error
    except OSError as error:
        raise _error(f"reportを書き込めません: {path}: {error}") from error


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, required=True,
                        help="既定5パッチ適用済みのmpv/ffmpegを含む隔離ソースディレクトリ")
    parser.add_argument("--tool-dir", type=Path, required=True,
                        help="patches/とversion_probe.cを含む隔離tool/ios_videoディレクトリ")
    parser.add_argument("--report", type=Path,
                        help="新規作成するJSONレポート。省略時はJSONを標準出力へ出す")
    args = parser.parse_args(argv)
    try:
        report_path = _validate_report_path(args.report) if args.report is not None else None
        result = apply_notices(args.source_dir, args.tool_dir)
        if report_path is None:
            print(json.dumps(result, ensure_ascii=False, indent=2))
        else:
            _write_report(report_path, result)
    except (NoticeError, OSError, ValueError) as error:
        print(f"中止: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
