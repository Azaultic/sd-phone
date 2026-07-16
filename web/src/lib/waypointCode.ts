
import { t } from '@/i18n';

export const ICON_KEYS = [
    'MapPin', 'Home', 'Star', 'Flag', 'Skull', 'DollarSign',
    'Car', 'Crosshair', 'Heart', 'Wrench', 'ShoppingCart', 'Fuel',
] as const;

export interface WaypointMarker {
    label: string;
    x:     number;
    y:     number;
    icon:  string;
    color: string;
}

const PREFIX = 'SDW1:';

interface Packed { l: string; x: number; y: number; i: string; c: string }

function b64urlEncode(s: string): string {
    const b64 = btoa(unescape(encodeURIComponent(s)));
    return b64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function b64urlDecode(s: string): string {
    const b64 = s.replace(/-/g, '+').replace(/_/g, '/');
    return decodeURIComponent(escape(atob(b64)));
}

export function encodeWaypoint(m: WaypointMarker): string {
    const packed: Packed = { l: m.label, x: Math.round(m.x), y: Math.round(m.y), i: m.icon, c: m.color };
    return PREFIX + b64urlEncode(JSON.stringify(packed));
}

export function decodeWaypoint(raw: string): WaypointMarker | null {
    if (!raw) return null;
    const at = raw.indexOf(PREFIX);
    if (at < 0) return null;
    const token = raw.slice(at + PREFIX.length).trim().split(/\s/)[0];
    if (!token) return null;
    try {
        const p = JSON.parse(b64urlDecode(token)) as Partial<Packed>;
        if (typeof p.x !== 'number' || typeof p.y !== 'number' || !Number.isFinite(p.x) || !Number.isFinite(p.y)) return null;
        const icon = typeof p.i === 'string' && (ICON_KEYS as readonly string[]).includes(p.i) ? p.i : 'MapPin';
        const color = typeof p.c === 'string' && /^#[0-9a-fA-F]{3,8}$/.test(p.c) ? p.c : '#5c6cf3';
        const label = (typeof p.l === 'string' ? p.l : '').slice(0, 40) || t('maps.sharedWaypoint', 'Shared waypoint');
        return { label, x: p.x, y: p.y, icon, color };
    } catch {
        return null;
    }
}

