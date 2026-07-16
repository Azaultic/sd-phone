
const FRAME_COLORS: Record<string, string> = {
    black:  '#292e28',
    blue:   '#3a9bc8',
    green:  '#28c329',
    orange: '#c68028',
    pink:   '#d75fc9',
    purple: '#a689b7',
    red:    '#9d3431',
    yellow: '#dfb431',
};

export const DEFAULT_FRAME_COLOR = 'black';

function clamp(n: number): number { return Math.max(0, Math.min(255, Math.round(n))); }

function parse(hex: string): [number, number, number] {
    const h = hex.replace('#', '');
    return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)];
}

function toHex(r: number, g: number, b: number): string {
    return '#' + [r, g, b].map(v => clamp(v).toString(16).padStart(2, '0')).join('');
}

function mix(hex: string, target: number, amt: number): string {
    const [r, g, b] = parse(hex);
    return toHex(r + (target - r) * amt, g + (target - g) * amt, b + (target - b) * amt);
}

const lighten = (hex: string, amt: number) => mix(hex, 255, amt);
const darken  = (hex: string, amt: number) => mix(hex, 0, amt);

export interface FrameStops { s0: string; s20: string; s45: string; s68: string; s100: string }

export function frameStops(name: string): FrameStops {
    const base = FRAME_COLORS[name] ?? FRAME_COLORS[DEFAULT_FRAME_COLOR];
    return {
        s0:   lighten(base, 0.30),
        s20:  base,
        s45:  darken(base, 0.30),
        s68:  base,
        s100: lighten(base, 0.14),
    };
}
