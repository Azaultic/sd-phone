import { context } from '@/media/sfx';

const TONES: Record<string, [number, number]> = {
    '1': [697, 1209], '2': [697, 1336], '3': [697, 1477],
    '4': [770, 1209], '5': [770, 1336], '6': [770, 1477],
    '7': [852, 1209], '8': [852, 1336], '9': [852, 1477],
    '*': [941, 1209], '0': [941, 1336], '#': [941, 1477],
};

export function playDtmf(key: string): void {
    const pair = TONES[key];
    const ac = context();
    if (!pair || !ac) return;
    if (ac.state === 'suspended') void ac.resume();

    const now = ac.currentTime;
    const dur = 0.13;

    const gain = ac.createGain();
    gain.gain.setValueAtTime(0.0001, now);
    gain.gain.exponentialRampToValueAtTime(0.2, now + 0.012);
    gain.gain.setValueAtTime(0.2, now + dur - 0.03);
    gain.gain.exponentialRampToValueAtTime(0.0001, now + dur);
    gain.connect(ac.destination);

    for (const freq of pair) {
        const osc = ac.createOscillator();
        osc.type = 'sine';
        osc.frequency.value = freq;
        osc.connect(gain);
        osc.start(now);
        osc.stop(now + dur);
    }
}
