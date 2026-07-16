
export function ancestorZoom(el: HTMLElement | null): number {
    let z = 1;
    for (let n: HTMLElement | null = el; n; n = n.parentElement) {
        const cz = parseFloat(getComputedStyle(n).getPropertyValue('zoom'));
        if (cz > 0 && cz !== 1) z *= cz;
    }
    return z || 1;
}

export function trackFraction(el: HTMLElement, clientX: number): number | null {
    const r = el.getBoundingClientRect();
    const w = el.offsetWidth;
    if (w <= 0 || r.width <= 0) return null;
    const factor = (r.width / w) / ancestorZoom(el);
    return Math.max(0, Math.min(1, (clientX * factor - r.left) / r.width));
}

export function trackFractionY(el: HTMLElement, clientY: number): number | null {
    const r = el.getBoundingClientRect();
    const h = el.offsetHeight;
    if (h <= 0 || r.height <= 0) return null;
    const factor = (r.height / h) / ancestorZoom(el);
    return Math.max(0, Math.min(1, (clientY * factor - r.top) / r.height));
}
