import { useEffect } from 'react';

import { ancestorZoom } from '@/lib/zoom';
import { useThemeStore } from '@/stores/themeStore';

const SAMPLE_MS = 300;
const DARK_BELOW = 0.5;
const FRACS = [0.2, 0.8];

interface RGBA { r: number; g: number; b: number; a: number }

function parseRGBA(value: string): RGBA | null {
    const m = value.match(/rgba?\(([^)]+)\)/);
    if (!m) return null;
    const p = m[1].split(',').map(v => parseFloat(v.trim()));
    if (p.length < 3 || p.some(n => Number.isNaN(n))) return null;
    return { r: p[0], g: p[1], b: p[2], a: p.length >= 4 ? p[3] : 1 };
}

function luma({ r, g, b }: RGBA): number {
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255;
}

function readBg(el: Element): number | 'image' | null {
    const cs = getComputedStyle(el);
    const col = parseRGBA(cs.backgroundColor);
    if (col && col.a >= 0.5) return luma(col);
    if (cs.backgroundImage && cs.backgroundImage !== 'none') return 'image';
    return null;
}

function sampleIframe(iframe: HTMLIFrameElement, fx: number, edge: 'top' | 'bottom'): number | 'image' | null {
    try {
        const doc = iframe.contentDocument;
        const root = doc?.documentElement;
        if (!doc || !root) return null;
        const w = root.clientWidth;
        const h = root.clientHeight;
        if (w < 2 || h < 2) return null;
        const ix = Math.max(1, Math.min(w - 1, fx * w));
        const iy = edge === 'top' ? Math.min(24, h * 0.06) : Math.max(1, h - Math.min(16, h * 0.05));
        for (const el of doc.elementsFromPoint(ix, iy)) {
            const v = readBg(el);
            if (v != null) return v;
        }
        return null;
    } catch {
        return null;
    }
}

function lumaAt(cx: number, cy: number, fx: number, edge: 'top' | 'bottom'): number | null {
    for (const el of document.elementsFromPoint(cx, cy)) {
        if (el instanceof HTMLIFrameElement) {
            const inner = sampleIframe(el, fx, edge);
            return inner == null || inner === 'image' ? null : inner;
        }
        const v = readBg(el);
        if (v === 'image') return null;
        if (v != null) return v;
    }
    return null;
}

function pointFromFraction(el: HTMLElement, fx: number, fy: number): { cx: number; cy: number } | null {
    const r = el.getBoundingClientRect();
    const w = el.offsetWidth;
    const h = el.offsetHeight;
    if (!w || !h || r.width < 2 || r.height < 2) return null;
    const z = ancestorZoom(el);
    const kx = (z * w) / r.width;
    const ky = (z * h) / r.height;
    return { cx: (r.left + fx * r.width) * kx, cy: (r.top + fy * r.height) * ky };
}

function sampleStrip(screen: HTMLElement, edge: 'top' | 'bottom'): boolean | null {
    const fy = edge === 'top' ? 0.03 : 0.985;
    let sum = 0;
    let n = 0;
    for (const fx of FRACS) {
        const pt = pointFromFraction(screen, fx, fy);
        if (!pt) continue;
        const l = lumaAt(pt.cx, pt.cy, fx, edge);
        if (l == null) continue;
        sum += l;
        n += 1;
    }
    if (n === 0) return null;
    return sum / n < DARK_BELOW;
}

export function useAutoContrast(enabled: boolean, sampleKey: string): void {
    useEffect(() => {
        if (!enabled) {
            const st = useThemeStore.getState();
            if (st.statusBarAutoLight !== null || st.homeAutoLight !== null) st.setAutoContrast(null, null);
            return;
        }
        const run = () => {
            const screen = document.querySelector('[data-phone-screen]') as HTMLElement | null;
            if (!screen) return;
            const top = sampleStrip(screen, 'top');
            const bottom = sampleStrip(screen, 'bottom');
            const st = useThemeStore.getState();
            if (top !== st.statusBarAutoLight || bottom !== st.homeAutoLight) st.setAutoContrast(top, bottom);
        };
        run();
        const id = window.setInterval(run, SAMPLE_MS);
        return () => window.clearInterval(id);
    }, [enabled, sampleKey]);
}
