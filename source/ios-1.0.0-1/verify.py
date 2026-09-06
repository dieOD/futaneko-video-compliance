#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (c) 2026 FutaNeko contributors
"""配布キットの全ファイルをSHA-256一覧と照合する（展開済みディレクトリ用）。"""
import hashlib
from pathlib import Path
import sys


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def verify(root):
    expected = {}
    for line in (root / 'SHA256SUMS').read_text(encoding='utf-8').splitlines():
        checksum, separator, name = line.partition('  ')
        path = Path(name)
        if (separator != '  ' or len(checksum) != 64
                or any(c not in '0123456789abcdef' for c in checksum)
                or not name or path.is_absolute() or '..' in path.parts
                or path.as_posix() != name or '\\' in name
                or any(ord(c) < 32 for c in name)
                or name in expected or name == 'SHA256SUMS'):
            raise ValueError('SHA256SUMSの形式が不正です')
        expected[name] = checksum
    actual = {}
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            raise ValueError('キットにシンボリックリンクがあります')
        if path.is_dir():
            continue
        if not path.is_file():
            raise ValueError('キットに通常ファイル以外があります')
        name = path.relative_to(root).as_posix()
        if name != 'SHA256SUMS':
            actual[name] = digest(path)
    if not expected or expected != actual:
        raise ValueError('ファイルの不足・追加・改変があります。元のキットを確認してください')
    return len(actual)


if __name__ == '__main__':
    try:
        print(f'配布キット検証: {verify(Path(__file__).resolve().parent)}ファイル合格')
    except (OSError, ValueError) as error:
        print(f'検証失敗: {error}', file=sys.stderr)
        sys.exit(1)
