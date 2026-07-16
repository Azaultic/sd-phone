import { IG } from './data';

const SEAL = (() => {
    const cx = 12, cy = 12, bumps = 8, R = 11.6, r = 8.6, n = bumps * 2;
    const pts: [number, number][] = [];
    for (let i = 0; i < n; i++) {
        const a = (Math.PI * 2 * i) / n - Math.PI / 2;
        const rad = i % 2 === 0 ? R : r;
        pts.push([cx + rad * Math.cos(a), cy + rad * Math.sin(a)]);
    }
    const mid = (p: [number, number], q: [number, number]): [number, number] => [(p[0] + q[0]) / 2, (p[1] + q[1]) / 2];
    const f = (x: number) => x.toFixed(2);
    const m0 = mid(pts[n - 1], pts[0]);
    let d = `M ${f(m0[0])} ${f(m0[1])}`;
    for (let i = 0; i < n; i++) {
        const m = mid(pts[i], pts[(i + 1) % n]);
        d += ` Q ${f(pts[i][0])} ${f(pts[i][1])} ${f(m[0])} ${f(m[1])}`;
    }
    return d + ' Z';
})();

export function VerifiedCheck({ size = 13 }: { size?: number }) {
    return (
        <svg width={size} height={size} viewBox="0 0 24 24" className="shrink-0" aria-hidden>
            <path d={SEAL} fill={IG.blue} />
            <path d="M7 12.4 L10.4 15.8 L17 8.6" fill="none" stroke="#fff" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
    );
}
