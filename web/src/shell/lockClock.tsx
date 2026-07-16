
import type { CSSProperties } from 'react';

import { readJson, writeJson } from '@/lib/storage';

export interface LockClock {
    font:   string;
    layout: string;
    color:  string;
    scale:  number;
}

export const CLOCK_SCALE_MIN = 0.7;
export const CLOCK_SCALE_MAX = 1.4;

export const DEFAULT_LOCK_CLOCK: LockClock = {
    font:   'rounded',
    layout: 'centered',
    color:  '#ffffff',
    scale:  1,
};


export const CLOCK_FONTS = [
    { id: 'rounded',    label: 'Rounded'    },
    { id: 'sans',       label: 'Sans'       },
    { id: 'serif',      label: 'Serif'      },
    { id: 'serifLight', label: 'Serif Thin' },
    { id: 'italic',     label: 'Italic'     },
    { id: 'italicSans', label: 'Slant'      },
    { id: 'script',     label: 'Script'     },
    { id: 'mono',       label: 'Mono'       },
    { id: 'typewriter', label: 'Typewriter' },
    { id: 'light',      label: 'Light'      },
    { id: 'condensed',  label: 'Condensed'  },
    { id: 'wide',       label: 'Wide'       },
    { id: 'black',      label: 'Black'      },
    { id: 'outline',    label: 'Outline'    },
    { id: 'striped',    label: 'Striped'    },
    { id: 'shadow',     label: 'Shadow'     },
    { id: 'neon',       label: 'Neon'       },
    { id: 'pop',        label: 'Pop'        },
    { id: 'chrome',     label: 'Chrome'     },
    { id: 'retro',      label: 'Retro'      },
] as const;

const STACK_ROUND  = '"SF Pro Rounded", ui-rounded, -apple-system, "Segoe UI", Inter, system-ui, sans-serif';
const STACK_SANS   = 'Inter, "SF Pro Display", -apple-system, "Segoe UI", system-ui, sans-serif';
const STACK_SERIF  = 'Georgia, "Times New Roman", "Noto Serif", serif';
const STACK_MONO   = 'ui-monospace, "SF Mono", "Cascadia Mono", "Roboto Mono", "Courier New", monospace';
const STACK_COND   = '"Arial Narrow", "Roboto Condensed", "Helvetica Neue Condensed", "Arial", sans-serif';
const STACK_TYPE   = '"Courier New", "Courier", ui-monospace, monospace';
const STACK_SCRIPT = '"Snell Roundhand", "Segoe Script", "Brush Script MT", "Bradley Hand", cursive';

export function clockFontStyle(fontId: string, color: string): CSSProperties {
    switch (fontId) {
        case 'sans':       return { fontFamily: STACK_SANS,   fontWeight: 800, letterSpacing: '-0.03em', color };
        case 'serif':      return { fontFamily: STACK_SERIF,  fontWeight: 700, letterSpacing: '-0.01em', color };
        case 'serifLight': return { fontFamily: STACK_SERIF,  fontWeight: 400, letterSpacing: '0.02em',  color };
        case 'italic':     return { fontFamily: STACK_SERIF,  fontWeight: 600, fontStyle: 'italic', letterSpacing: '-0.01em', color };
        case 'italicSans': return { fontFamily: STACK_SANS,   fontWeight: 800, fontStyle: 'italic', letterSpacing: '-0.02em', color };
        case 'script':     return { fontFamily: STACK_SCRIPT, fontWeight: 600, fontStyle: 'italic', letterSpacing: '0.01em', color };
        case 'mono':       return { fontFamily: STACK_MONO,   fontWeight: 700, letterSpacing: '-0.04em', color };
        case 'typewriter': return { fontFamily: STACK_TYPE,   fontWeight: 700, letterSpacing: '-0.02em', color };
        case 'light':      return { fontFamily: STACK_SANS,   fontWeight: 200, letterSpacing: '0.01em',  color };
        case 'condensed':  return { fontFamily: STACK_COND,   fontWeight: 700, letterSpacing: '-0.01em', color, display: 'inline-block', transform: 'scaleX(0.82)', transformOrigin: 'center' };
        case 'wide':       return { fontFamily: STACK_SANS,   fontWeight: 600, letterSpacing: '0.04em',  color, display: 'inline-block', transform: 'scaleX(1.16)', transformOrigin: 'center' };
        case 'black':      return { fontFamily: `"Arial Black", "Archivo Black", "Helvetica Neue", Impact, ${STACK_SANS}`, fontWeight: 900, letterSpacing: '-0.045em', color };
        case 'outline':    return { fontFamily: STACK_SANS,   fontWeight: 800, letterSpacing: '-0.01em', color: 'transparent', WebkitTextStroke: `0.04em ${color}` } as CSSProperties;
        case 'striped':    return {
            fontFamily: STACK_SANS, fontWeight: 800, letterSpacing: '-0.01em',
            color: 'transparent', WebkitTextStroke: `0.018em ${color}`,
            backgroundImage: `repeating-linear-gradient(${color} 0 0.055em, transparent 0.055em 0.15em)`,
            WebkitBackgroundClip: 'text', backgroundClip: 'text',
        } as CSSProperties;
        case 'shadow':     return { fontFamily: STACK_SANS,  fontWeight: 800, letterSpacing: '-0.02em', color, textShadow: `0.035em 0.05em 0 rgba(0,0,0,0.32), 0.07em 0.1em 0 rgba(0,0,0,0.16)` };
        case 'neon':       return { fontFamily: STACK_ROUND, fontWeight: 700, letterSpacing: '-0.01em', color, textShadow: `0 0 0.16em ${color}, 0 0 0.34em ${color}` };
        case 'pop':        return { fontFamily: STACK_ROUND, fontWeight: 800, letterSpacing: '-0.005em', color, WebkitTextStroke: `0.055em rgba(255,255,255,0.92)`, paintOrder: 'stroke' } as CSSProperties;
        case 'chrome':     return { fontFamily: STACK_SANS,  fontWeight: 800, letterSpacing: '-0.02em', color, textShadow: `0.016em 0.016em 0 #cdced3, 0.032em 0.032em 0 #a9aab0, 0.05em 0.05em 0 #86878e, 0.066em 0.066em 0.04em rgba(0,0,0,0.42)` };
        case 'retro':      return {
            fontFamily: STACK_SANS, fontWeight: 800, letterSpacing: '0',
            color: 'transparent', WebkitTextStroke: `0.028em ${color}`,
            backgroundImage: `repeating-linear-gradient(${color} 0 0.075em, transparent 0.075em 0.2em)`,
            WebkitBackgroundClip: 'text', backgroundClip: 'text',
        } as CSSProperties;
        case 'rounded':
        default:           return { fontFamily: STACK_ROUND, fontWeight: 700, letterSpacing: '-0.015em', color };
    }
}

function clockDateStyle(color: string): CSSProperties {
    return { fontFamily: STACK_ROUND, fontWeight: 600, letterSpacing: '0.005em', color };
}


export const CLOCK_LAYOUTS = [
    { id: 'centered', label: 'Centered'    },
    { id: 'stacked',  label: 'Stacked'     },
    { id: 'left',     label: 'Left'         },
    { id: 'right',    label: 'Right'        },
    { id: 'dateTop',  label: 'Date on top' },
] as const;


export const CLOCK_COLORS = [
    '#f2f2f7', '#64d2ff', '#7d9bf5', '#c9b8f5',
    '#bf5af2', '#ff6f91', '#ff8f86', '#e3a977',
    '#34c759', '#30d6c0', '#ffd60a', '#ff9f0a',
    '#ff453a', '#5e5ce6', '#ff375f', '#aeaeb2',
    '#9ee37d', '#9fd8ff', '#ffb6cd', '#7b3ff2',
    '#a2845e', '#ff7a5c', '#3b6fe0', '#7d8aa3',
    '#ffffff', '#b8f2d8', '#1ca7a0', '#2aa7e0',
    '#ff4fa3', '#d62246', '#e0a82e', '#5a5a60',
] as const;


const LS_KEY = 'sd-phone:lock-clock';

export function loadLockClockLocal(): LockClock {
    const p = readJson<Partial<LockClock>>(LS_KEY);
    return p ? { ...DEFAULT_LOCK_CLOCK, ...p } : DEFAULT_LOCK_CLOCK;
}

export function saveLockClockLocal(cfg: LockClock): void {
    writeJson(LS_KEY, cfg);
}


export function Clockface({ time, date, config, size, showDate = true, shadow = true }: {
    time:      string;
    date:      string;
    config:    LockClock;
    size:      number;
    showDate?: boolean;
    shadow?:   boolean;
}) {
    const s = size * (config.scale || 1);
    const timeStyle = { fontSize: s, lineHeight: 0.95, ...clockFontStyle(config.font, config.color) };
    const dateSize  = Math.max(9, Math.round(s * 0.214));
    const dateEl = showDate ? (
        <div style={{ fontSize: dateSize, lineHeight: 1.1, marginTop: Math.round(s * 0.04), ...clockDateStyle(config.color) }}>
            {date}
        </div>
    ) : null;

    const [hh, mm] = time.split(':');
    const timeEl = config.layout === 'stacked' ? (
        <div style={{ ...timeStyle, lineHeight: 0.86 }}>
            <div>{hh}</div>
            <div>{mm}</div>
        </div>
    ) : (
        <div style={timeStyle}>{time}</div>
    );

    const alignClass = config.layout === 'left'  ? 'items-start text-left'
                     : config.layout === 'right' ? 'items-end text-right'
                     : 'items-center text-center';
    const filter = shadow ? 'drop-shadow(0 1px 4px rgba(0,0,0,0.4))' : undefined;

    return (
        <div className={`flex select-none flex-col ${alignClass}`} style={{ filter }}>
            {config.layout === 'dateTop' ? <>{dateEl}{timeEl}</> : <>{timeEl}{dateEl}</>}
        </div>
    );
}
