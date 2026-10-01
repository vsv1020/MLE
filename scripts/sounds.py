#!/usr/bin/env python3
"""Generate VocabLoop's sound effects.

There are no audio assets in the repository and no audio tooling on the build machines, so the
ten short effects are synthesised here from sines and triangles with nothing but the standard
library. The output is deterministic: running the script twice produces byte-identical files, so
regenerating never shows up as a spurious diff.

    python3 scripts/sounds.py            # writes VocabLoop/Resources/Sounds/*.wav
    python3 scripts/sounds.py --check    # exits 1 if a committed file differs from the generator

Format: mono, 16-bit PCM, 44.1 kHz — what AudioServicesCreateSystemSoundID plays without
conversion. Every file is under a second, and all ten together stay well under 400 KB.

Design rules (docs/ENGAGEMENT-PLAN.md §1.6): bright and short, nothing harsh, nothing that could
read as a "wrong" buzzer. There is deliberately no sound for Forgot, Slow or a wrong quiz answer.
"""

import io
import math
import os
import struct
import sys
import wave

RATE = 44_100
PEAK = 0.55  # Leave headroom: these play over speech and music, and should never be the loudest thing.

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'VocabLoop', 'Resources', 'Sounds')

# Equal-tempered note frequencies used below.
C5, E5, G5, C6, E6 = 523.25, 659.25, 783.99, 1046.50, 1318.51


# ── Building blocks ──────────────────────────────────────────────────────────────

def silence(seconds):
    return [0.0] * int(RATE * seconds)


def envelope(n, attack=0.004, release=0.03, decay=None):
    """Per-sample gain: a short linear attack, optional exponential decay, a linear release.

    The attack and release are what keep a synthesised tone from clicking at its edges.
    """
    a = max(1, int(RATE * attack))
    r = max(1, int(RATE * release))
    gains = []
    for i in range(n):
        g = 1.0
        if i < a:
            g *= i / a
        if i > n - r:
            g *= max(0.0, (n - i) / r)
        if decay:
            g *= math.exp(-i / (RATE * decay))
        gains.append(g)
    return gains


def sine(freq, seconds, phase=0.0):
    n = int(RATE * seconds)
    return [math.sin(phase + 2 * math.pi * freq * i / RATE) for i in range(n)]


def triangle(freq, seconds):
    n = int(RATE * seconds)
    out = []
    for i in range(n):
        t = (freq * i / RATE) % 1.0
        out.append(4 * t - 1 if t < 0.5 else 3 - 4 * t)
    return out


def sweep(f0, f1, seconds):
    """Sine whose frequency glides linearly from f0 to f1 (phase-continuous)."""
    n = int(RATE * seconds)
    out = []
    phase = 0.0
    for i in range(n):
        f = f0 + (f1 - f0) * i / max(1, n - 1)
        phase += 2 * math.pi * f / RATE
        out.append(math.sin(phase))
    return out


def shaped(samples, **kwargs):
    gains = envelope(len(samples), **kwargs)
    return [s * g for s, g in zip(samples, gains)]


def mix(*tracks):
    n = max(len(t) for t in tracks)
    out = [0.0] * n
    for track in tracks:
        for i, s in enumerate(track):
            out[i] += s
    return out


def scale(samples, factor):
    return [s * factor for s in samples]


def offset(samples, seconds):
    return silence(seconds) + samples


def bell(freq, seconds, decay):
    """A soft chime: fundamental plus two quiet partials, decaying exponentially."""
    tone = mix(
        sine(freq, seconds),
        scale(sine(freq * 2.0, seconds), 0.35),
        scale(sine(freq * 3.01, seconds), 0.12),
    )
    return shaped(tone, attack=0.003, release=0.05, decay=decay)


def note_sequence(freqs, note_seconds, last_seconds=None, voice=sine, decay=0.12):
    out = []
    for index, freq in enumerate(freqs):
        seconds = last_seconds if (last_seconds and index == len(freqs) - 1) else note_seconds
        tone = mix(voice(freq, seconds), scale(sine(freq * 2, seconds), 0.2))
        out += shaped(tone, attack=0.003, release=min(0.03, seconds / 3), decay=decay)
    return out


def shimmer(seconds, start=0.0, count=6):
    """High, quiet, decaying partials at fixed staggered times: a sparkle without randomness."""
    tracks = []
    for k in range(count):
        freq = 2600 + 330 * k
        at = start + k * 0.035
        tone = shaped(sine(freq, 0.12), attack=0.002, release=0.04, decay=0.04)
        tracks.append(offset(scale(tone, 0.25), at))
    total = int(RATE * seconds)
    out = mix(*tracks)
    return (out + [0.0] * total)[:total]


def fit(samples, seconds):
    """Pad or trim to exactly `seconds`, fading the last few ms so a trim never clicks."""
    n = int(RATE * seconds)
    out = (samples + [0.0] * n)[:n]
    fade = min(n, int(RATE * 0.01))
    for i in range(fade):
        out[n - fade + i] *= (fade - i) / fade
    return out


def normalise(samples, peak=PEAK):
    top = max((abs(s) for s in samples), default=0.0)
    return samples if top == 0 else [s * peak / top for s in samples]


# ── The ten effects ──────────────────────────────────────────────────────────────

def reveal():
    # 70 ms soft pop, sine gliding 520 → 380 Hz.
    return fit(shaped(sweep(520, 380, 0.07), attack=0.004, release=0.03), 0.07)


def correct():
    # 120 ms bright ding on E6.
    return fit(bell(E6, 0.12, decay=0.05), 0.12)


def combo_small():
    # C5–E5, 160 ms.
    return fit(note_sequence([C5, E5], 0.08), 0.16)


def combo_medium():
    # C5–E5–G5, 220 ms.
    return fit(note_sequence([C5, E5, G5], 0.07, last_seconds=0.08), 0.22)


def combo_big():
    # C5–E5–G5–C6 plus a shimmer, 400 ms.
    arpeggio = note_sequence([C5, E5, G5, C6], 0.07, last_seconds=0.19, decay=0.15)
    return fit(mix(arpeggio, shimmer(0.4, start=0.2)), 0.40)


def candy():
    # Two 40 ms sparkles at 1.8 and 2.4 kHz.
    first = shaped(sine(1800, 0.04), attack=0.002, release=0.015, decay=0.03)
    second = shaped(sine(2400, 0.04), attack=0.002, release=0.015, decay=0.03)
    return fit(first + silence(0.01) + second, 0.09)


def sticker():
    # 300 ms rising shimmer: a glide with a light tremolo and sparkles on top.
    glide = sweep(900, 1800, 0.3)
    tremolo = [0.75 + 0.25 * math.sin(2 * math.pi * 18 * i / RATE) for i in range(len(glide))]
    body = shaped([s * t for s, t in zip(glide, tremolo)], attack=0.01, release=0.08)
    return fit(mix(scale(body, 0.8), shimmer(0.3, start=0.08, count=5)), 0.30)


def level_up():
    # 800 ms triangle-wave fanfare C–E–G–C.
    fanfare = note_sequence([C5, E5, G5, C6], 0.13, last_seconds=0.41, voice=triangle, decay=0.4)
    return fit(fanfare, 0.80)


def badge():
    # 600 ms chime: two bell strikes, G5 then C6, ringing together.
    return fit(mix(bell(G5, 0.6, decay=0.22), offset(bell(C6, 0.48, decay=0.2), 0.12)), 0.60)


def goal():
    # 1.0 s warm chime: a soft C-major chord arriving note by note.
    chord = mix(
        bell(C5, 1.0, decay=0.45),
        offset(scale(bell(E5, 0.92, decay=0.42), 0.8), 0.08),
        offset(scale(bell(G5, 0.84, decay=0.4), 0.7), 0.16),
    )
    return fit(chord, 1.0)


EFFECTS = {
    'reveal': reveal,
    'correct': correct,
    'combo_3': combo_small,
    'combo_10': combo_medium,
    'combo_big': combo_big,
    'candy': candy,
    'sticker': sticker,
    'level_up': level_up,
    'badge': badge,
    'goal': goal,
}


# ── Output ────────────────────────────────────────────────────────────────────────

def encode(samples):
    frames = b''.join(
        struct.pack('<h', max(-32767, min(32767, int(round(s * 32767)))))
        for s in normalise(samples)
    )
    buffer = io.BytesIO()
    with wave.open(buffer, 'wb') as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(frames)
    return buffer.getvalue()


def main(argv):
    check = '--check' in argv
    os.makedirs(OUT_DIR, exist_ok=True)
    total = 0
    stale = []
    for name, build in EFFECTS.items():
        data = encode(build())
        total += len(data)
        path = os.path.join(OUT_DIR, f'{name}.wav')
        if check:
            try:
                with open(path, 'rb') as existing:
                    if existing.read() != data:
                        stale.append(name)
            except FileNotFoundError:
                stale.append(name)
        else:
            with open(path, 'wb') as out:
                out.write(data)
        print(f'{name + ".wav":16s} {len(data) / 1024:6.1f} KB')
    print(f'{"total":16s} {total / 1024:6.1f} KB')
    if total > 400 * 1024:
        print('Sound effects exceed the 400 KB budget.')
        return 1
    if stale:
        print('Out of date: ' + ', '.join(stale) + ' (run python3 scripts/sounds.py)')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
