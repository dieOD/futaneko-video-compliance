#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright (c) 2026 FutaNeko contributors
"""原本アーカイブから、隔離コピー内で動画部品だけを再構築する。"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

# importした補助コードのキャッシュも入力キットには書き込まない。
sys.dont_write_bytecode = True
from verify import verify


def prepare(kit, mpv_patch=None, ffmpeg_patch=None):
    verify(kit)
    patches = {}
    for component, value in [('mpv', mpv_patch), ('ffmpeg', ffmpeg_patch)]:
        if value is not None:
            path = value.resolve(strict=True)
            if not path.is_file() or path.stat().st_size > 16 * 1024 * 1024:
                raise ValueError('追加パッチは16 MiB以下の通常ファイルにしてください')
            patches[component] = path.read_bytes()
    work = Path(tempfile.mkdtemp(prefix='nijineko-ios-video-kit.', dir='/private/tmp'))
    workspace = work / 'workspace'
    try:
        # コピー中の改変・リンク混入も、コードを実行する前に検査する。
        shutil.copytree(kit, workspace, symlinks=True)
        verify(workspace)
        verify(kit)
        if not (workspace / 'add_source_notices.py').is_file():
            raise ValueError('変更通知を付ける補助コードがありません')
        shutil.copytree(workspace / 'archives', work / 'downloads')
        script = workspace / 'tool/ios_video/build_ios_video.sh'
        content = script.read_text(encoding='utf-8')
        # 原本の既定パッチ適用後、利用者が指定した変更だけをコピー内へ追加する。
        marker = 'clang_path=$(xcrun --find clang)'
        if content.count(marker) != 1:
            raise ValueError('ビルドスクリプトの版が異なります')
        additions = []
        changes = {}
        for component, data in patches.items():
            patch = work / f'user-{component}.patch'
            patch.write_bytes(data)
            changes[component] = hashlib.sha256(data).hexdigest()
            additions.append(
                f'patch --batch --forward --directory "$source_dir/{component}" '
                f'-p1 --input {shlex.quote(str(patch))}'
            )
        additions.append(
            f'{shlex.quote(sys.executable)} -B {shlex.quote(str(workspace / "add_source_notices.py"))} '
            '--source-dir "$source_dir" --tool-dir "$script_dir" '
            f'--report {shlex.quote(str(work / "source-modification-notices.json"))}'
        )
        script.write_text(content.replace(marker, '\n'.join(additions) + '\n\n' + marker), encoding='utf-8')
        result = {
            'workspace': str(workspace), 'native_build': str(work),
            'build_command': ['bash', str(script)],
            'audit_command': ['bash', str(workspace / 'tool/ios_video/audit_ios_video.sh')],
            'additional_patch_sha256': changes,
            'original_kit_unchanged': True,
        }
        (work / 'rebuild-request.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        return result
    except BaseException:
        shutil.rmtree(work)  # この実行で作った未完成の隔離コピーだけ。
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare-only', action='store_true', help='隔離コピー作成まで行う')
    parser.add_argument('--mpv-patch', type=Path, help='自分で確認したmpv用の追加-p1パッチ')
    parser.add_argument('--ffmpeg-patch', type=Path, help='自分で確認したFFmpeg用の追加-p1パッチ')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('macOSとXcodeが必要です')
    try:
        result = prepare(Path(__file__).resolve().parent, args.mpv_patch, args.ffmpeg_patch)
        print(json.dumps(result, ensure_ascii=False), flush=True)
        if not args.prepare_only:
            import os
            env = {**os.environ, 'NIJINEKO_IOS_VIDEO_BUILD_ROOT': result['native_build']}
            subprocess.run(result['build_command'], env=env, check=True)
            subprocess.run(result['audit_command'], env=env, check=True)
            print('再構築・静的監査成功。成果物は上記workspace内に保存しました。')
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'中止: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
