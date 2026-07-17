interface RGBA { r: number; g: number; b: number; a: number }

export function parseRGBA(value: string): RGBA | null {
    const m = value.match(/rgba?\(([^)]+)\)/);
    if (!m) return null;
    const p = m[1].split(',').map(v => parseFloat(v.trim()));
    if (p.length < 3 || p.some(n => Number.isNaN(n))) return null;
    return { r: p[0], g: p[1], b: p[2], a: p.length >= 4 ? p[3] : 1 };
}

export function luma(c: RGBA): number {
    return (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) / 255;
}

export function bgLuma(backgroundColor: string, backgroundImage: string): number | 'image' | null {
    const col = parseRGBA(backgroundColor);
    if (col && col.a >= 0.5) return luma(col);
    if (backgroundImage && backgroundImage !== 'none') {
        if (backgroundImage.includes('gradient')) {
            const stops = backgroundImage.match(/rgba?\([^)]+\)/g);
            if (stops) {
                let sum = 0;
                let n = 0;
                for (const s of stops) {
                    const c = parseRGBA(s);
                    if (c && c.a >= 0.3) { sum += luma(c); n += 1; }
                }
                if (n > 0) return sum / n;
            }
        }
        return 'image';
    }
    return null;
}
