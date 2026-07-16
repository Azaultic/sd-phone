import { context, noiseBuffer } from '@/media/sfx';

export function playCrunch(): void {
    const ac = context();
    if (!ac) return;
    if (ac.state === 'suspended') void ac.resume();

    const now = ac.currentTime;
    const v   = 0.85 + Math.random() * 0.3;

    const src = ac.createBufferSource();
    src.buffer = noiseBuffer(ac);
    const bp = ac.createBiquadFilter();
    bp.type = 'bandpass';
    bp.frequency.value = 1600 * v;
    bp.Q.value = 0.7;
    const ng = ac.createGain();
    ng.gain.setValueAtTime(0.0001, now);
    ng.gain.exponentialRampToValueAtTime(0.3, now + 0.004);
    ng.gain.exponentialRampToValueAtTime(0.0001, now + 0.08);
    src.connect(bp); bp.connect(ng); ng.connect(ac.destination);
    src.start(now); src.stop(now + 0.09);

    const osc = ac.createOscillator();
    osc.type = 'triangle';
    osc.frequency.setValueAtTime(440 * v, now);
    osc.frequency.exponentialRampToValueAtTime(150, now + 0.07);
    const og = ac.createGain();
    og.gain.setValueAtTime(0.0001, now);
    og.gain.exponentialRampToValueAtTime(0.28, now + 0.005);
    og.gain.exponentialRampToValueAtTime(0.0001, now + 0.08);
    osc.connect(og); og.connect(ac.destination);
    osc.start(now); osc.stop(now + 0.08);
}
