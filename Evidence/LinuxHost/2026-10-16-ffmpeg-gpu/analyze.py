#!/usr/bin/env python3
"""汇总正式三轮样本；调试探针不计入性能结论。"""
import json
import pathlib
import statistics

ROOT = pathlib.Path(__file__).resolve().parent
LABELS = ['gpu-r1', 'ram-r1', 'ram-r2', 'gpu-r2', 'gpu-r3', 'ram-r3']


def read_jsonl(name):
    return [json.loads(s) for s in (ROOT/name).read_text().splitlines()]


def summarize(label):
    records = read_jsonl(label+'.jsonl')
    complete = records[-1]
    assert complete['event'] == 'complete' and not complete['issues']
    assert complete['exit_code'] in (None, 0)
    controller = json.loads((ROOT/(label+'-controller.json')).read_text())
    assert not controller['controller_errors'] and controller['ssh_exit'] == 0 and controller['received_final']
    samples = [s for s in records if s['event'] == 'sample']
    viewer = read_jsonl(label+'-viewer.jsonl')
    assert len({r['coreGeneration'] for r in viewer}) == 1
    assert all(r['coreState'] == 'streaming' for r in viewer)
    errors = {k: max(r['pipeline'][k] for r in viewer)-min(r['pipeline'][k] for r in viewer)
              for k in ('decodeErrors','decoderResets','referenceFrameDrops','packetSequenceGaps')}
    assert not any(errors.values())
    timing = [(s['elapsed_s'], int(s['ffmpeg_progress']['frame'])) for s in samples if 'ffmpeg_progress' in s]
    fps = None
    if timing:
        xbar = statistics.mean(x for x, y in timing)
        ybar = statistics.mean(y for x, y in timing)
        fps = sum((x-xbar)*(y-ybar) for x,y in timing)/sum((x-xbar)**2 for x,y in timing)
    mem = {}
    for row in complete['final'].values():
        group = row['group']
        m = row['memory_kib']
        dest = mem.setdefault(group, {'pss_mib':0., 'uss_mib':0.})
        dest['pss_mib'] += m['Pss']/1024
        dest['uss_mib'] += (m['Private_Clean']+m['Private_Dirty'])/1024
    return {'label':label, 'mode':complete['mode'], 'sample_duration_s':complete['sample_duration_s'],
            'sample_start_utc':complete['sample_start_utc'], 'end_utc':complete['end_utc'],
            'means':complete['summary'], 'ffmpeg_measured_fps':fps, 'final_memory':mem,
            'viewer':{'samples':len(viewer), 'generation':viewer[0]['coreGeneration'], 'error_deltas':errors,
                      'received_fps_mean':statistics.mean(r['pipeline']['receivedFPS'] for r in viewer),
                      'presented_fps_mean':statistics.mean(r['pipeline']['presentedFPS'] for r in viewer),
                      'received_fps_min':min(r['pipeline']['receivedFPS'] for r in viewer),
                      'max_receive_age_ms':max(r['pipeline']['videoReceiveAgeMS'] for r in viewer),
                      'max_presentation_age_ms':max(r['pipeline']['presentationAgeMS'] for r in viewer)},
            'issues':complete['issues']}


def main():
    cases = [summarize(label) for label in LABELS]
    baselines = [summarize(x) for x in ('baseline-pre','baseline-post')]
    modes = {}
    for mode in ('gpu','ram'):
        matching = [c for c in cases if c['mode'] == mode]
        cpu = [c['means']['ffmpeg_cpu'] for c in matching]
        modes[mode] = {'ffmpeg_cpu_median':statistics.median(cpu), 'ffmpeg_cpu_range':[min(cpu),max(cpu)],
                       'fps_median':statistics.median(c['ffmpeg_measured_fps'] for c in matching),
                       'pss_mib_median':statistics.median(c['final_memory']['ffmpeg']['pss_mib'] for c in matching),
                       'concurrent_rustdesk_cpu_median':statistics.median(c['means']['rustdesk_cpu'] for c in matching),
                       'concurrent_drm_recv_cpu_median':statistics.median(c['means']['drm_recv_cpu'] for c in matching),
                       'compositor_cpu_median':statistics.median(c['means']['compositor_cpu'] for c in matching)}
    reduction = 100*(1-modes['gpu']['ffmpeg_cpu_median']/modes['ram']['ffmpeg_cpu_median'])
    summary = {'cpu_unit':'100 percent = one logical CPU', 'cases':cases, 'baselines':baselines,
               'modes':modes, 'ffmpeg_pipeline_cpu_reduction_pct':reduction,
               'limitations':['FFmpeg RAM control is not RustDesk code',
                              'Live desktop content was not controlled or changed by this experiment',
                              'Current linear framebuffer only; no tiled/DCC compatibility claim',
                              'No full client performance, picture-quality, latency, cursor, or reconnect acceptance']}
    (ROOT/'summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps({'modes':modes,'pipeline_cpu_reduction_pct':reduction},indent=2))


if __name__ == '__main__':
    main()
