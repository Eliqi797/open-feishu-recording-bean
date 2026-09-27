"""Resumable bounded-memory processing. A checkpoint never substitutes for source validation."""
from __future__ import annotations

import copy
import hashlib
import json
import os
import re
import time
import wave
from pathlib import Path

from .settings import get as setting

from .core import Problem, atomic_write, digest
from .providers import title_once, pcm_audio, transcribe, llm_once, NVIDIA_FUNCTION


def save(path, value):
    atomic_write(path, json.dumps(value, ensure_ascii=False, allow_nan=False).encode())


def key_for(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def checkpoint(path, key):
    if not path.exists():
        return None
    try:
        value = json.loads(path.read_text())
        if value['key'] == key and key_for(value['result']) == value['result_hash']:
            return value['result']
    except (ValueError, KeyError, TypeError):
        pass
    return None


def store_checkpoint(path, key, result):
    save(path, {'key': key, 'result': result, 'result_hash': key_for(result)})


def transcribe_resumable(source: Path, work: Path, hotwords=None, chunk_seconds=None, recognizer=None):
    work.mkdir(parents=True, exist_ok=True, mode=0o700)
    recognize = recognizer or transcribe
    seconds = chunk_seconds or int(setting('ASR_CHUNK_SECONDS', '300'))
    if setting('ASR_PROVIDER') == 'nvidia_whisper':seconds=min(seconds,60)
    if not 1 <= seconds <= 1800:
        raise Problem('INVALID_ASR_CHUNK_SECONDS')
    source_hash = digest(source)
    converted = work / 'converted.wav'
    audio = pcm_audio(source, converted)
    combined, chunks = [], []
    profile = {'source_hash': source_hash, 'seconds': seconds, 'hotwords': hotwords or [],
               'speaker_zero_policy': setting('NVIDIA_SPEAKER_ZERO_POLICY', 'unknown'),
               'format': setting('ASR_RESPONSE_FORMAT'), 'provider': setting('ASR_PROVIDER'), 'base': setting('ASR_BASE_URL'), 'model': setting('ASR_MODEL'), 'language': setting('ASR_LANGUAGE'),
               'max_speakers': setting('NVIDIA_MAX_SPEAKERS', '8'), 'model_function': NVIDIA_FUNCTION, 'version': 4}
    try:
        with wave.open(str(audio)) as wav:
            rate, count = wav.getframerate(), wav.getnframes()
            chunk_frames = rate * seconds
            for index, offset in enumerate(range(0, count, chunk_frames)):
                size = min(chunk_frames, count - offset)
                cache = work / f'chunk-{index}.json'
                key = key_for({**profile, 'index': index, 'offset': offset, 'frames': size})
                result = checkpoint(cache, key)
                # Retry unrecognized audio on an explicit rerun; keep successful chunks.
                if result and result.get('recognition_status') == 'no_transcript':
                    result = None
                reused = result is not None
                if result is None:
                    part = work / f'chunk-{index}.wav'
                    silent = True
                    wav.setpos(offset)
                    with wave.open(str(part), 'wb') as output:
                        output.setparams((1, 2, rate, 0, 'NONE', 'not compressed'))
                        left = size
                        while left:
                            block = wav.readframes(min(left, 65536))
                            if not block:
                                raise Problem('AUDIO_TRUNCATED', 422)
                            silent = silent and not any(block)
                            output.writeframesraw(block)
                            left -= len(block) // 2
                    try:
                        if silent:
                            result = {'segments': [], 'text': '', 'source': 'digital-silence', 'speaker_accuracy_verified': False}
                        else:
                            try:
                                result = recognize(part, work / f'chunk-{index}-raw-{time.time_ns()}.json',
                                                   diarization=True, hotwords=hotwords or [])
                            except Problem as error:
                                if error.code != 'ASR_NO_FINAL_TRANSCRIPT':
                                    raise
                                # No returned text is not proof of silence. Continue later audio,
                                # expose the gap, and retain raw evidence for another attempt.
                                result = {'segments': [], 'text': '', 'source': setting('ASR_PROVIDER','nvidia_parakeet'),
                                          'recognition_status': 'no_transcript', 'speaker_accuracy_verified': False}
                        store_checkpoint(cache, key, result)
                    finally:
                        part.unlink(missing_ok=True)
                start_ms = offset * 1000 // rate
                for original in result['segments']:
                    segment = copy.deepcopy(original)
                    segment['id'] = len(combined)
                    segment['chunk_index'] = index
                    for entry in [segment, *segment.get('words', [])]:
                        for field in ('start_ms', 'end_ms'):
                            if entry.get(field) is not None:
                                entry[field] += start_ms
                        if entry.get('speaker_id') is not None:
                            entry['speaker_id'] = f"chunk-{index}:" + entry['speaker_id'].split(':')[-1]
                    combined.append(segment)
                chunks.append({'index': index, 'start_ms': start_ms, 'end_ms': (offset + size) * 1000 // rate,
                               'checkpoint_reused': reused, 'digital_silence': result.get('source') == 'digital-silence',
                               'recognition_status': result.get('recognition_status', 'digital_silence' if result.get('source') == 'digital-silence' else 'transcribed')})
                save(work / 'progress.json', {'completed_chunks': index + 1, 'total_chunks': (count + chunk_frames - 1) // chunk_frames})
        gaps = [c for c in chunks if c['recognition_status'] == 'no_transcript']
        coverage = {'status': 'partial' if gaps else 'complete', 'unrecognized_chunks': gaps,
                    'note': '未返回文字的片段不等于静音；原始音频保留，需回听核对。' if gaps else ''}
        save(work / 'coverage.json', coverage)
        if not combined:
            raise Problem('ASR_NO_FINAL_TRANSCRIPT' if gaps else 'ASR_NO_SPEECH', 422)
        return {'schema_version': 2, 'source': setting('ASR_PROVIDER','nvidia_parakeet'), 'text': '\n'.join(s['text'] for s in combined),
                'segments': combined, 'chunks': chunks, 'coverage': coverage, 'source_sha256': source_hash,
                'speaker_tags_observed': any(w.get('speaker_id') is not None for s in combined for w in s.get('words', [])),
                'speaker_accuracy_verified': False, 'cross_chunk_speakers_merged': False,
                'chunk_boundary_note': 'Fixed contiguous chunks; boundary recognition accuracy requires long-audio acceptance.'}
    finally:
        if audio == converted:
            converted.unlink(missing_ok=True)


def review_actions(value, source, segments):
    result = copy.deepcopy(value)
    accepted, rejected = [], []
    by_id = {str(s['id']): s['text'] for s in segments}
    for action in result['actions']:
        evidence = action['evidence'].strip()
        match = re.fullmatch(r'\[(\d+)\]', evidence)
        grounding = by_id.get(match[1], '') if match else evidence
        if not grounding or grounding not in source:
            rejected.append({**action, 'reason': 'EVIDENCE_NOT_IN_SOURCE'})
            continue
        item = dict(action)
        for name in ('owner', 'due_date'):
            if item.get(name) and item[name] not in grounding:
                result['uncertainties'].append(f"待办“{item['task']}”的{name}未在所引依据中明确，已留空。")
                item[name] = None
        accepted.append(item)
    result['actions'], result['rejected_actions'] = accepted, rejected
    if rejected:
        result['uncertainties'].append(f'{len(rejected)} 条候选待办未找到对应原文依据，未列为已确认待办。')
    return result


def summarize_resumable(transcript, work: Path, summarizer=None, chunk_chars=8000):
    work.mkdir(parents=True, exist_ok=True, mode=0o700)
    summarize = summarizer or llm_once
    segments = transcript['segments']
    text = '\n'.join(f"[{s['id']}] {s['text']}" for s in segments)
    if not text.strip():
        raise Problem('EMPTY_TRANSCRIPT')
    parts = []
    for index, start in enumerate(range(0, len(text), chunk_chars)):
        content = text[start:start + chunk_chars]
        key = key_for({'text': content, 'model': setting('LLM_MODEL'), 'base': setting('LLM_BASE_URL'), 'version': 2})
        path = work / f'part-{index}.json'
        value = checkpoint(path, key)
        if value is None:
            raw_path = work / f'part-{index}-raw-{time.time_ns()}.json'
            value = summarize(content, raw_path=raw_path)
            value = review_actions(value, content, segments)
            store_checkpoint(path, key, value)
        parts.append(value)
    # Preserve each grounded item; only the narrative is reduced and never truncated.
    narratives = [p['summary'] for p in parts]
    level = 0
    while len(narratives) > 1:
        reduced = []
        for i in range(0, len(narratives), 2):
            if i + 1 == len(narratives):
                reduced.append(narratives[i]); continue
            content = '\n'.join(narratives[i:i + 2])
            key = key_for({'text': content, 'model': setting('LLM_MODEL'), 'base': setting('LLM_BASE_URL'), 'version': 2})
            path = work / f'reduce-{level}-{i}.json'
            value = checkpoint(path, key)
            if value is None:
                value = summarize('以下是分段纪要，只合并摘要，不补充事实：\n' + content,
                                  raw_path=work / f'reduce-{level}-{i}-raw-{time.time_ns()}.json')
                store_checkpoint(path, key, value)
            reduced.append(value['summary'])
        narratives = reduced; level += 1
    def unique(items):
        seen, output = set(), []
        for item in items:
            key = key_for(item)
            if key not in seen:
                output.append(item); seen.add(key)
        return output
    result = {'summary': narratives[0], **{k: unique(v for p in parts for v in p.get(k, []))
            for k in ('decisions', 'actions', 'uncertainties', 'rejected_actions')},
            'parts': parts, 'human_review_required': True, 'source_hash': key_for(transcript)}
    gaps = transcript.get('coverage', {}).get('unrecognized_chunks', [])
    if gaps:
        ranges = ', '.join(f"{c['start_ms'] // 1000}–{c['end_ms'] // 1000} 秒" for c in gaps)
        result['uncertainties'].insert(0, '以下时段没有识别文字，不能认定为静音；本纪要仅覆盖已识别内容，请回听：' + ranges)
    if summarizer is None:
        title_key=key_for({'summary':result['summary'],'model':setting('LLM_MODEL'),'base':setting('LLM_BASE_URL'),'version':1})
        title_path=work/'title.json';title=checkpoint(title_path,title_key)
        if title is None:
            title={'title':title_once(result['summary'])};store_checkpoint(title_path,title_key,title)
        result['title']=title['title']
    return result
