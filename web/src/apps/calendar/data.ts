import { readJson, writeJson } from '@/lib/storage';
import { format12h } from '@/lib/time';

const STORAGE_KEY = 'sd-phone:calendar:v1';

export interface CalEvent {
    id:       string;
    dayKey:   string;
    title:    string;
    allDay:   boolean;
    start?:   string;
    end?:     string;
    location: string;
    notes:    string;
    color:    string;
}

export interface CalState {
    events:   CalEvent[];
    dayNotes: Record<string, string>;
}

const empty: CalState = { events: [], dayNotes: {} };

export function loadState(): CalState {
    const raw = readJson<Partial<CalState>>(STORAGE_KEY);
    return raw
        ? {
            events:   Array.isArray(raw.events) ? raw.events : [],
            dayNotes: raw.dayNotes && typeof raw.dayNotes === 'object' ? raw.dayNotes : {},
        }
        : empty;
}

export function saveState(s: CalState): void {
    writeJson(STORAGE_KEY, s);
}


export function dayKey(d: Date): string {
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${y}-${m}-${day}`;
}

export function isSameDay(a: Date, b: Date): boolean {
    return a.getFullYear() === b.getFullYear()
        && a.getMonth()    === b.getMonth()
        && a.getDate()     === b.getDate();
}

export function addMonths(d: Date, n: number): Date {
    return new Date(d.getFullYear(), d.getMonth() + n, 1);
}

export const MONTH_NAMES = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
];

export const WEEKDAY_SHORT = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

export function monthGrid(d: Date): Date[] {
    const first = new Date(d.getFullYear(), d.getMonth(), 1);
    const startCol = first.getDay();
    const gridStart = new Date(d.getFullYear(), d.getMonth(), 1 - startCol);
    const out: Date[] = [];
    for (let i = 0; i < 42; i++) {
        out.push(new Date(gridStart.getFullYear(), gridStart.getMonth(), gridStart.getDate() + i));
    }
    return out;
}

export function formatLongDate(d: Date): string {
    const wk = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'][d.getDay()];
    return `${wk}, ${MONTH_NAMES[d.getMonth()]} ${d.getDate()}`;
}

export function formatTime(hhmm: string): string {
    const [hStr, mStr] = hhmm.split(':');
    const h = Number(hStr);
    const m = Number(mStr);
    return format12h(h, m);
}

export { newId } from '@/lib/format';

export const EVENT_COLORS = [
    '#ff453a', // red
    '#ff9f0a', // orange
    '#ffd60a', // yellow
    '#34c759', // green
    '#0a84ff', // blue
    '#5e5ce6', // indigo
    '#bf5af2', // purple
];
