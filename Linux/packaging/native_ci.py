"""Run the Linux source-to-candidate pipeline with explicit input provenance."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import time
import urllib.parse

import native_build_tools as tools
import native_bundle
import native_package_source
import native_receipt
import native_privacy
from native_source_build import inventory

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'Build/Linux'


def public_record(value):
    """Keep executable local logs private; export portable command/path records."""
    if isinstance(value, str):
        return value.replace(str(ROOT), '.')
    if isinstance(value, list):
        return [public_record(item) for item in value]
    if isinstance(value, dict):
        return {key: public_record(item) for key, item in value.items()}
    return value


def json_tail(text):
    start = 0 if text.startswith('{\n') else text.rindex('\n{\n') + 1
    return json.loads(text[start:])


def container_path(path):
    return '/workspace/' + Path(path).resolve().relative_to(ROOT).as_posix()


def extract(archive, expected, output):
    tools.require(tools.digest(archive) == expected, 'Source archive SHA-256 mismatch')
    with tarfile.open(archive) as stream:
        members = stream.getmembers()
        roots = {Path(m.name).parts[0] for m in members}
        tools.require(len(roots) == 1 and next(iter(roots)).startswith('farpane-native-source-'),
                      'Unexpected source archive root')
        tools.require(len(members) < 200000 and sum(m.size for m in members) <= 10 * 1024**3,
                      'Source archive exceeds the extraction limit')
        stream.extractall(output, filter='data')
    source = output / roots.pop()
    manifest = json.loads((source / 'source-manifest.json').read_text())
    tools.require(manifest['schema'] == 1 and manifest['kind'] == 'farpane-native-source-snapshot',
                  'Wrong source snapshot')
    tools.require(inventory(source, ('source-manifest.json',)) == manifest['files'],
                  'Extracted source inventory mismatch')
    original = json.loads((source / 'binary-build-receipt.json').read_text())
    tools.require(original['sources'] == native_receipt.sources(),
                  'Archive application sources differ from this CI checkout')
    return source, manifest


def verify_reuse(application, source, manifest):
    receipt, _, proof = native_package_source.load(application, native_receipt.sources())
    current_hash = tools.digest(source / 'source-manifest.json')
    if current_hash != proof['source_manifest_sha256']:
        tools.require(manifest.get('compiled_source_build', {}).get('source_build_result_sha256')
                      == proof['source_build_result_sha256'], 'Archive does not bind the reused build')
        prefixes = ('Build/Linux/src/', 'Build/Linux/gui/', 'Build/Linux/native/')
        for name, entry in manifest['files'].items():
            if not name.startswith(prefixes):
                continue
            path = application / 'workspace' / name
            if 'sha256' in entry:
                tools.require(path.is_file() and not path.is_symlink() and
                              tools.digest(path) == entry['sha256'], 'Reused prepared source differs: ' + name)
            else:
                tools.require(path.is_symlink() and str(path.readlink()) == entry['symlink'],
                              'Reused source link differs: ' + name)
    return receipt, proof


def pipeline(args):
    tools.require(os.geteuid() != 0, 'Run the pipeline as an ordinary user')
    tools.require(re.fullmatch('[0-9a-f]{64}', args.sha256), 'Expected a source SHA-256')
    tools.require(re.fullmatch('[0-9][0-9A-Za-z.+~\\-]*', args.version), 'Invalid candidate version')
    tools.require((os.cpu_count() or 0) >= 4 and
                  os.sysconf('SC_PHYS_PAGES') * os.sysconf('SC_PAGE_SIZE') >= 12 * 1024**3,
                  'The build requires at least 4 CPUs and 12 GiB RAM')
    parent = BUILD / 'native-ci'
    parent.mkdir(parents=True, exist_ok=True)
    if args.output:
        output = args.output.resolve()
        tools.require(output.is_relative_to(parent) and output != parent, 'CI output must be under Build/Linux/native-ci/')
        output.mkdir()  # Never resume/overwrite a partially completed CI directory.
    else:
        output = Path(tempfile.mkdtemp(prefix='run.', dir=parent))
    print('ci_output=' + str(output), flush=True)
    stages = {}

    def run(name, command, extra_env=None, stdin=None, timeout=7200):
        print('Running ' + name, flush=True)
        began = time.monotonic()
        with (output / (name + '.stdout')).open('w') as stdout, (output / (name + '.stderr')).open('w') as stderr:
            process = subprocess.run([str(x) for x in command], cwd=ROOT, stdin=stdin,
                                     stdout=stdout, stderr=stderr, timeout=timeout,
                                     env=dict(os.environ, **(extra_env or {})))
        stages[name] = {'command': [str(x) for x in command], 'returncode': process.returncode,
                        'seconds': time.monotonic() - began,
                        'stdout_sha256': tools.digest(output / (name + '.stdout')),
                        'stderr_sha256': tools.digest(output / (name + '.stderr'))}
        (output / 'stages.json').write_text(json.dumps(stages, indent=2) + '\n')
        tools.require(process.returncode == 0, name + ' failed; inspect its logs in ' + str(output))
        return (output / (name + '.stdout')).read_text()

    if args.source_url:
        url = urllib.parse.urlsplit(args.source_url)
        tools.require(url.scheme == 'https' and not url.username and not url.password and
                      not url.query and not url.fragment, 'Use a public HTTPS source archive URL without credentials')
        pin = {'tools': {'source': {'filename': 'source.tar.gz', 'url': args.source_url,
                                   'algorithm': 'sha256', 'digest': args.sha256, 'max_bytes': 2 * 1024**3}}}
        tools.fetch(pin, output / 'download')
        archive = output / 'download/source.tar.gz'
    else:
        archive = args.archive.resolve(strict=True)
    print('Verifying and extracting the source archive', flush=True)
    source, manifest = extract(archive, args.sha256, output / 'source')
    native_privacy.require_clean(source)
    source_hash = tools.digest(source / 'source-manifest.json')
    input_record = {'archive_sha256': args.sha256, 'source_manifest_sha256': source_hash,
                    'source_entries': len(manifest['files']), 'version': args.version,
                    'ci_checkout': native_package_source.identity(ROOT),
                    'reuse_build': bool(args.reuse_build), 'reuse_images': args.reuse_images}
    (output / 'inputs.json').write_text(json.dumps(input_record, indent=2) + '\n')
    for name, image, dockerfile in [
        ('builder', args.builder_image, 'Linux/packaging/native-source-builder.Dockerfile'),
        ('runtime', args.runtime_image, 'Linux/packaging/native-runtime-ubuntu2404.Dockerfile'),
    ]:
        if not args.reuse_images:
            with (ROOT / dockerfile).open('rb') as context:
                run('image-' + name, ['docker', 'build', '--network', 'default', '--memory', '12g',
                    '--cpu-period', '100000', '--cpu-quota', '400000', '--tag', image, '-'],
                    {'DOCKER_BUILDKIT': '0'}, context)
        run('inspect-' + name, ['docker', 'image', 'inspect', image, '--format', '{{.Id}}'])
    command = ['python3', '-B', 'Scripts/linux/prepare-native-tools.py', '--image', args.builder_image]
    if args.reuse_sdk:
        command += ['--reuse-sdk', args.reuse_sdk.resolve(strict=True)]
    if args.offline_tools:
        command += ['--offline']
    prepared = json_tail(run('tools', command))
    sdk = Path(prepared['sdk'])
    if args.reuse_build:
        application = args.reuse_build.resolve(strict=True)
        tools.require(application.is_relative_to(BUILD / 'native-bootstrap'), 'Expected an owned source build')
        verify_reuse(application, source, manifest)
    else:
        deps_stdout = run('dependencies', ['bash', 'Scripts/linux/build-native-dependencies.sh', source,
            source_hash, prepared['tools']['vcpkg']['path'], prepared['tools']['cmake']['path'], args.builder_image])
        dependencies = Path(deps_stdout.splitlines()[0])
        dependency_hash = tools.digest(dependencies / 'installed-manifest.json')
        app_stdout = run('application', ['bash', 'Scripts/linux/build-native-source.sh', source,
            source_hash, dependencies, dependency_hash, args.builder_image], {'FARPANE_NATIVE_RUST_SDK': str(sdk)})
        application = Path(app_stdout.splitlines()[0])
        verify_reuse(application, source, manifest)

    def package_command(script, arguments):
        # No generated checkout or original product media prefix is mounted at
        # /workspace/Build/Linux/src. Dependency notices come from application.
        mounts = []
        for name in ('Linux', 'Scripts', '.git', 'LICENSE', 'THIRD_PARTY_NOTICES.md'):
            path = ROOT / name
            if path.exists():
                mounts += ['--mount', f'type=bind,src={path},dst=/workspace/{name},readonly']
        # A scratch /workspace exists in tmpfs; only artifact/deb outputs and
        # the selected completed source build are writable/readable respectively.
        for folder in ('artifacts', 'debian'):
            (BUILD / folder).mkdir(exist_ok=True)
            mounts += ['--mount', f'type=bind,src={BUILD / folder},dst=/workspace/Build/Linux/{folder}']
        mounts += ['--mount', f'type=bind,src={application},dst={container_path(application)},readonly']
        for relative in ('source-manifest.json', 'native-dependencies/notice-delivery'):
            mounts += ['--mount', f'type=bind,src={source / relative},dst=/workspace/{relative},readonly']
        return ['docker', 'run', '--rm', '--network', 'none', '--cpus', '4', '--memory', '12g',
                '--pids-limit', '512', '--user', f'{os.getuid()}:{os.getgid()}',
                '--tmpfs', f'/workspace:rw,exec,mode=755,uid={os.getuid()},gid={os.getgid()}',
                *mounts, '--workdir', '/workspace',
                '--entrypoint', 'python3', args.builder_image, '-B', script, *arguments]

    bundle_command = package_command('Scripts/linux/package-native.py',
                                     ['--source-build', container_path(application),
                                      '--version', args.version.replace('~', '-')])
    packaged = json_tail(run('bundle', bundle_command))
    artifact = ROOT / Path(packaged['artifact']).relative_to('/workspace')
    native_bundle.verify(artifact)
    debs = []
    for suffix, version in [('installcheck', args.version + '~installcheck'), ('candidate', args.version)]:
        record = json_tail(run('deb-' + suffix, package_command('Scripts/linux/package-native-deb.py',
                               [container_path(artifact), '--version', version])))
        debs.append(ROOT / Path(record['package']).relative_to('/workspace'))
    run('bundle-unit-tests', ['python3', '-B', '-m', 'unittest', 'discover', '-s', 'Linux/tests', '-p', 'test_native_bundle.py'])
    run('privacy-unit-tests', ['python3', '-B', '-m', 'unittest', 'discover', '-s', 'Linux/tests', '-p', 'test_native_privacy.py'])
    run('tools-unit-tests', ['python3', '-B', '-m', 'unittest', 'discover', '-s', 'Linux/tests', '-p', 'test_native_build_tools.py'])
    run('notice-unit-tests', ['python3', '-B', '-m', 'unittest', 'discover', '-s', 'Linux/tests', '-p', 'test_native_notice_supplements.py'])
    run('notice-delivery-tests', ['python3', '-B', '-m', 'unittest', 'discover', '-s', 'Linux/tests', '-p', 'test_native_notice_delivery.py'])
    # Protocol tests run in a separate empty target, with verified vendor and
    # SDK inputs. No compiler/artifact path from the original product is used.
    protocol = output / 'protocol'
    protocol.mkdir()
    run('protocol-tests', ['docker', 'run', '--rm', '--network', 'none', '--cpus', '4', '--memory', '12g',
        '--user', f'{os.getuid()}:{os.getgid()}',
        '--mount', f'type=bind,src={source},dst=/source,readonly',
        '--mount', f'type=bind,src={sdk},dst=/toolchain,readonly',
        '--mount', f'type=bind,src={protocol},dst=/output',
        '-e', 'CARGO_HOME=/output/cargo-home', '-e', 'CARGO_TARGET_DIR=/output/target', '-e', 'CARGO_BUILD_JOBS=4',
        '-e', 'PATH=/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        '--workdir', '/source', '--entrypoint', '/toolchain/bin/cargo', args.builder_image,
        'test', '--offline', '--locked', '--manifest-path', 'Build/Linux/gui/Cargo.toml', '-p', 'farpane-protocol', '--lib'])
    runtime_outputs = {}
    for name, folder, command in [
        ('package-runtime', 'native-package-smoke', ['bash', 'Scripts/linux/test-native-package.sh', artifact, 'ubuntu-24.04']),
        ('deb-runtime', 'native-deb-smoke', ['bash', 'Scripts/linux/test-native-deb.sh', *debs, 'ubuntu-24.04']),
    ]:
        parent = BUILD / folder
        before = set(parent.iterdir()) if parent.exists() else set()
        run(name, command, {'FARPANE_NATIVE_RUNTIME_IMAGE': args.runtime_image})
        created = set(parent.iterdir()) - before
        tools.require(len(created) == 1, 'Cannot identify the owned runtime result: ' + name)
        runtime_outputs[name] = str(created.pop())

    # Candidate artifacts are published to this new local directory only.
    deliverables = output / 'deliverables'
    deliverables.mkdir()
    for path in (artifact.with_suffix('.tar.gz'), debs[-1], archive):
        name = 'farpane-native-source-input.tar.gz' if path == archive else path.name
        shutil.copy2(path, deliverables / name)
    tools.require(tools.digest(deliverables / 'farpane-native-source-input.tar.gz') == args.sha256,
                  'Source archive changed before artifact collection')
    for name in ('native-build-tools.lock.json', 'dependencies.lock.json'):
        shutil.copy2(ROOT / 'Linux' / name, deliverables / name)
    (deliverables / 'README.txt').write_text(
        'FarPane Linux native GUI development candidate, x86_64. Includes GUI, core and media.\n'
        'Ubuntu 24.04 runtime smoke passed; Linux 6.5+, GTK 4.14+, libadwaita 1.5+ required.\n'
        'Installing the Debian candidate stages files; service/desktop activation is a separate maintenance transaction.\n'
        'No original RustDesk installation or host FFmpeg is required.\n'
        'Real desktop, hardware/long-run/performance and full license/source audit remain incomplete.\n'
        'Do not treat this CI artifact as an accepted public release.\n')
    result = {'result': 'pass', 'inputs': input_record, 'source_build_result_sha256': tools.digest(application / 'result.json'),
              'compiled_source_manifest_sha256': json.loads((application / 'result.json').read_text())['source_manifest_sha256'],
              'full_build_executed_this_run': not bool(args.reuse_build), 'validated_build_reused': bool(args.reuse_build),
              'application': str(application), 'artifact_id': artifact.name,
              'runtime_outputs': runtime_outputs, 'sdk_receipt_sha256': prepared['sdk_receipt_sha256'],
              'cloud_execution_attested': False, 'runtime_ready': False, 'complete_license_source_audit': False,
              'host_installed': False, 'published': False, 'stages': stages}
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    (deliverables / 'build-result.json').write_text(json.dumps(public_record(result), indent=2) + '\n')
    privacy_report = native_privacy.require_clean(deliverables)
    (deliverables / 'privacy-scan.json').write_text(json.dumps(privacy_report, indent=2) + '\n')
    (deliverables / 'SHA256SUMS').write_text(''.join(tools.digest(p) + '  ' + p.name + '\n'
        for p in sorted(deliverables.iterdir()) if p.is_file()))
    print(json.dumps({'result': 'pass', 'output': str(output), 'deliverables': str(deliverables),
                      'full_build_executed_this_run': not bool(args.reuse_build), 'published': False}, indent=2))
