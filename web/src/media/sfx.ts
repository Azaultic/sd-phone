
let ctx: AudioContext | null = null;

export function context(): AudioContext | null {
    if (typeof window === 'undefined') return null;
    const Ctor = window.AudioContext
        ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!Ctor) return null;
    ctx ??= new Ctor();
    return ctx;
}

let noise: AudioBuffer | null = null;
export function noiseBuffer(ac: AudioContext): AudioBuffer {
    if (noise) return noise;
    const len = Math.floor(ac.sampleRate * 0.2);
    const buf = ac.createBuffer(1, len, ac.sampleRate);
    const data = buf.getChannelData(0);
    for (let i = 0; i < len; i++) data[i] = Math.random() * 2 - 1;
    noise = buf;
    return buf;
}

export interface ChimeNote {
    f: number;
    at: number;
    dur: number;
}

export function playChime(ac: AudioContext, notes: ChimeNote[], peak: number, attack: number): void {
    const lp = ac.createBiquadFilter();
    lp.type = 'lowpass';
    lp.frequency.value = 3200;
    lp.connect(ac.destination);

    for (const n of notes) {
        const osc = ac.createOscillator();
        osc.type = 'triangle';
        osc.frequency.value = n.f;
        const g = ac.createGain();
        g.gain.setValueAtTime(0.0001, n.at);
        g.gain.exponentialRampToValueAtTime(peak, n.at + attack);
        g.gain.exponentialRampToValueAtTime(0.0001, n.at + n.dur);
        osc.connect(g); g.connect(lp);
        osc.start(n.at); osc.stop(n.at + n.dur + 0.02);
    }
}

export function playHit(): void {
    const ac = context();
    if (!ac) return;
    if (ac.state === 'suspended') void ac.resume();
    const now = ac.currentTime;

    const osc = ac.createOscillator();
    osc.type = 'triangle';
    osc.frequency.setValueAtTime(180, now);
    osc.frequency.exponentialRampToValueAtTime(55, now + 0.12);
    const og = ac.createGain();
    og.gain.setValueAtTime(0.0001, now);
    og.gain.exponentialRampToValueAtTime(0.34, now + 0.006);
    og.gain.exponentialRampToValueAtTime(0.0001, now + 0.18);
    osc.connect(og); og.connect(ac.destination);
    osc.start(now); osc.stop(now + 0.2);

    const src = ac.createBufferSource();
    src.buffer = noiseBuffer(ac);
    const lp = ac.createBiquadFilter();
    lp.type = 'lowpass';
    lp.frequency.setValueAtTime(2400, now);
    lp.frequency.exponentialRampToValueAtTime(380, now + 0.08);
    const ng = ac.createGain();
    ng.gain.setValueAtTime(0.0001, now);
    ng.gain.exponentialRampToValueAtTime(0.26, now + 0.004);
    ng.gain.exponentialRampToValueAtTime(0.0001, now + 0.1);
    src.connect(lp); lp.connect(ng); ng.connect(ac.destination);
    src.start(now); src.stop(now + 0.12);
}
