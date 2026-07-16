import { context } from '@/media/sfx';

type RingKind = 'ringback' | 'ringtone';

const CADENCE: Record<RingKind, { on: number; off: number; gain: number }> = {
    ringback: { on: 2.0, off: 4.0, gain: 0.14 },
    ringtone: { on: 1.2, off: 1.6, gain: 0.22 },
};

const RING_FREQS = [440, 480];

function burst(ac: AudioContext, gainPeak: number, duration: number): void {
    const now = ac.currentTime;
    const gain = ac.createGain();
    gain.gain.setValueAtTime(0.0001, now);
    gain.gain.exponentialRampToValueAtTime(gainPeak, now + 0.05);
    gain.gain.setValueAtTime(gainPeak, now + duration - 0.12);
    gain.gain.exponentialRampToValueAtTime(0.0001, now + duration);
    gain.connect(ac.destination);

    for (const freq of RING_FREQS) {
        const osc = ac.createOscillator();
        osc.type = 'sine';
        osc.frequency.value = freq;
        osc.connect(gain);
        osc.start(now);
        osc.stop(now + duration);
    }
}

export function startRing(kind: RingKind): () => void {
    const ac = context();
    if (!ac) return () => {};
    if (ac.state === 'suspended') void ac.resume();

    const { on, off, gain } = CADENCE[kind];
    burst(ac, gain, on);
    const interval = window.setInterval(() => burst(ac, gain, on), (on + off) * 1000);

    return () => window.clearInterval(interval);
}
