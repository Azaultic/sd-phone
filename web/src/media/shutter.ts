import { context, noiseBuffer } from './sfx';

function snap(ac: AudioContext, dest: AudioNode, t: number, vol: number, bright: number): void {
    const nb = noiseBuffer(ac);

    const a   = ac.createBufferSource(); a.buffer = nb;
    const ahp = ac.createBiquadFilter(); ahp.type = 'highpass'; ahp.frequency.value = 3600 * bright;
    const ag  = ac.createGain();
    ag.gain.setValueAtTime(0.0001, t);
    ag.gain.exponentialRampToValueAtTime(0.45 * vol, t + 0.0009);
    ag.gain.exponentialRampToValueAtTime(0.0001, t + 0.011);
    a.connect(ahp); ahp.connect(ag); ag.connect(dest);
    a.start(t); a.stop(t + 0.02);

    const partials: [number, number, number][] = [
        [1650, 6, 0.40],
        [3300, 9, 0.26],
    ];
    for (const [freq, q, gv] of partials) {
        const s  = ac.createBufferSource(); s.buffer = nb;
        const bp = ac.createBiquadFilter(); bp.type = 'bandpass'; bp.frequency.value = freq * bright; bp.Q.value = q;
        const g  = ac.createGain();
        g.gain.setValueAtTime(0.0001, t);
        g.gain.exponentialRampToValueAtTime(gv * vol, t + 0.0025);
        g.gain.exponentialRampToValueAtTime(0.0001, t + 0.05);
        s.connect(bp); bp.connect(g); g.connect(dest);
        s.start(t); s.stop(t + 0.06);
    }

    const o  = ac.createOscillator(); o.type = 'triangle';
    o.frequency.setValueAtTime(330, t);
    o.frequency.exponentialRampToValueAtTime(140, t + 0.04);
    const og = ac.createGain();
    og.gain.setValueAtTime(0.0001, t);
    og.gain.exponentialRampToValueAtTime(0.14 * vol, t + 0.004);
    og.gain.exponentialRampToValueAtTime(0.0001, t + 0.05);
    o.connect(og); og.connect(dest);
    o.start(t); o.stop(t + 0.06);
}

export function playShutter(volume = 0.7): void {
    const ac = context();
    if (!ac) return;
    if (ac.state === 'suspended') void ac.resume();
    const v = Math.max(0, Math.min(1, volume));
    if (v <= 0) return;

    const master = ac.createGain();
    master.gain.value = 0.6;
    master.connect(ac.destination);

    const now = ac.currentTime + 0.001;
    snap(ac, master, now,          0.65 * v, 1.15);
    snap(ac, master, now + 0.075,  0.9  * v, 0.95);
}
