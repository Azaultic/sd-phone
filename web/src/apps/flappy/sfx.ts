import { context, noiseBuffer, playChime, playHit } from '@/media/sfx';

export { playHit };

export function playFlap(): void {
    const ac = context();
    if (!ac) return;
    if (ac.state === 'suspended') void ac.resume();
    const now = ac.currentTime;

    const src = ac.createBufferSource();
    src.buffer = noiseBuffer(ac);
    const lp = ac.createBiquadFilter();
    lp.type = 'lowpass';
    lp.frequency.setValueAtTime(1900, now);
    lp.frequency.exponentialRampToValueAtTime(520, now + 0.12);
    const ng = ac.createGain();
    ng.gain.setValueAtTime(0.0001, now);
    ng.gain.exponentialRampToValueAtTime(0.22, now + 0.008);
    ng.gain.exponentialRampToValueAtTime(0.0001, now + 0.13);
    src.connect(lp); lp.connect(ng); ng.connect(ac.destination);
    src.start(now); src.stop(now + 0.14);

    const osc = ac.createOscillator();
    osc.type = 'sine';
    osc.frequency.setValueAtTime(540, now);
    osc.frequency.exponentialRampToValueAtTime(250, now + 0.09);
    const og = ac.createGain();
    og.gain.setValueAtTime(0.0001, now);
    og.gain.exponentialRampToValueAtTime(0.13, now + 0.006);
    og.gain.exponentialRampToValueAtTime(0.0001, now + 0.1);
    osc.connect(og); og.connect(ac.destination);
    osc.start(now); osc.stop(now + 0.1);
}

export function playCoin(): void {
    const ac = context();
    if (!ac) return;
    if (ac.state === 'suspended') void ac.resume();
    const now = ac.currentTime;

    playChime(ac, [
        { f: 784,  at: now,         dur: 0.11 },
        { f: 1047, at: now + 0.085, dur: 0.32 },
    ], 0.1, 0.006);
}
