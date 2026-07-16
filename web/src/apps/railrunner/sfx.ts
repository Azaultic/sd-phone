import { context, playChime, playHit } from '@/media/sfx';

export { playHit };

export function playJump(): void {
    const ac = context();
    if (!ac) return;
    if (ac.state === 'suspended') void ac.resume();
    const now = ac.currentTime;

    const osc = ac.createOscillator();
    osc.type = 'square';
    osc.frequency.setValueAtTime(330, now);
    osc.frequency.exponentialRampToValueAtTime(720, now + 0.1);
    const g = ac.createGain();
    g.gain.setValueAtTime(0.0001, now);
    g.gain.exponentialRampToValueAtTime(0.16, now + 0.006);
    g.gain.exponentialRampToValueAtTime(0.0001, now + 0.13);
    const lp = ac.createBiquadFilter();
    lp.type = 'lowpass';
    lp.frequency.value = 2600;
    osc.connect(g); g.connect(lp); lp.connect(ac.destination);
    osc.start(now); osc.stop(now + 0.14);
}

export function playCoin(): void {
    const ac = context();
    if (!ac) return;
    if (ac.state === 'suspended') void ac.resume();
    const now = ac.currentTime;

    playChime(ac, [
        { f: 784,  at: now,         dur: 0.1 },
        { f: 1047, at: now + 0.07,  dur: 0.26 },
    ], 0.09, 0.005);
}
